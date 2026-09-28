require "log"

module Crystalfaux
  class Page
    # :nodoc:
    #
    # Follows the network events of one page: runs the page's request and
    # response handlers, applies the context's block rules to intercepted
    # requests, and tells each `Response` when its request finished.
    #
    # Fibers: the page calls the event methods on the connection's reader
    # fiber, and they never block. For each intercepted request, the
    # traffic spawns one fiber that decides it: it aborts a request that a
    # block rule matches, else runs the request handlers in order until
    # one decides, and continues the request when none did. For each
    # response, it spawns one fiber that runs the response handlers in
    # order. These fibers end when the handlers return; a request action
    # that fails because the page closed ends them too. Handlers that
    # raise are logged. The traffic cannot stop a handler that blocks on
    # something else, such as its own channel or IO.
    #
    # The page calls `#dispose` when it closes or crashes. It drops the
    # handlers and the registry, and fails the body wait of every
    # unfinished response. A closed page has removed its subscriptions; a
    # crashed page keeps them until it closes, and the traffic ignores the
    # events that still arrive.
    class Traffic
      Log = ::Log.for("crystalfaux.network")

      @lock = Sync::Mutex.new
      # Requests without a finished or failed event yet, by request id.
      @requests = {} of String => Request
      # Responses whose request has not finished yet, by request id.
      @responses = {} of String => Response
      @request_handlers = [] of Request ->
      @response_handlers = [] of Response ->
      @failure : Exception?

      def add_request_handler(handler : Request ->) : Nil
        @lock.synchronize { @request_handlers << handler }
      end

      def remove_request_handler(handler : Request ->) : Nil
        @lock.synchronize { @request_handlers.delete(handler) }
      end

      def add_response_handler(handler : Response ->) : Nil
        @lock.synchronize { @response_handlers << handler }
      end

      def request_will_be_sent(page : Page, event : Protocol::Network::RequestWillBeSent) : Nil
        request = Request.new(page, event)
        @lock.synchronize do
          return if @failure
          @requests[request.id] = request
        end
        spawn(name: "crystalfaux-request") { decide(request) } if request.intercepted?
      end

      def response_received(event : Protocol::Network::ResponseReceived) : Nil
        handlers, response = @lock.synchronize do
          request = @requests[event.request_id]?
          return unless request
          received = Response.new(request, event)
          @responses[request.id] = received
          {@response_handlers.dup, received}
        end
        return if handlers.empty?
        spawn(name: "crystalfaux-response") { handlers.each { |handler| run(handler, response) } }
      end

      def request_finished(request_id : String) : Nil
        forget(request_id).try &.finish
      end

      def request_failed(event : Protocol::Network::RequestFailed) : Nil
        request_id = event.request_id
        forget(request_id).try &.finish(Error.new("Request #{request_id} failed: #{event.error_code}"))
      end

      # Fails the body wait of every unfinished response with *reason*.
      # Only the first reason counts.
      def dispose(reason : Exception) : Nil
        responses = @lock.synchronize do
          return if @failure
          @failure = reason
          @requests.clear
          @request_handlers.clear
          @response_handlers.clear
          @responses.values.tap { @responses.clear }
        end
        responses.each(&.finish(reason))
      end

      private def forget(request_id : String) : Response?
        @lock.synchronize do
          @requests.delete(request_id)
          @responses.delete(request_id)
        end
      end

      private def decide(request : Request) : Nil
        if request.page.context.blocks?(request)
          request.abort("blockedbyclient")
          return
        end
        @lock.synchronize { @request_handlers.dup }.each do |handler|
          run(handler, request)
          return if request.decided?
        end
        request.continue
      rescue ex : Error
        # The page closed or crashed, or the browser rejected the decision.
        Log.debug(exception: ex) { "Could not decide request #{request.url}" }
      end

      private def run(handler : T ->, argument : T) : Nil forall T
        handler.call(argument)
      rescue ex
        Log.error(exception: ex) { "Network handler raised" }
      end
    end
  end
end
