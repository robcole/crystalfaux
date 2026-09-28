module Crystalfaux
  # Camoufox fingerprint configs: the `CAMOU_CONFIG` object that the browser
  # reads at startup (Camoufox `additions/camoucfg/MaskConfig.hpp`).
  #
  # Camoufox's Python and TypeScript packages generate configs with a
  # statistical model; crystalfaux does not port it. Give `Config` a
  # document that `launch_options()` or `launchOptions()` produced, or build
  # a small deterministic one with `Config.for`.
  #
  # ```
  # config = Crystalfaux::Fingerprint::Config.for(
  #   os: :mac,
  #   screen: Crystalfaux::Fingerprint::Screen.new(1512, 982),
  #   user_agent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:152.0) Gecko/20100101 Firefox/152.0",
  # )
  # browser = Crystalfaux::Browser.launch(config: config)
  # ```
  #
  # The key list and the per-OS font lists are vendored in `data/camoufox/`
  # from the Camoufox commit of `protocol/Protocol.js` (MPL-2.0).
  module Fingerprint
    # A width and height in CSS pixels.
    record Screen, width : Int32, height : Int32
  end
end
