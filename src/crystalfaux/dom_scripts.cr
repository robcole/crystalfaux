# Portions of this file are translated from Playwright
# (https://github.com/microsoft/playwright):
# - `packages/injected/src/domUtils.ts` (`isElementVisible`)
# - `packages/injected/src/injectedScript.ts` (`expectHitTarget`,
#   `elementState`)
# - `packages/injected/src/roleUtils.ts` (`getAriaRole`,
#   `isElementHiddenForAria`, `getElementAccessibleName`)
#
# Copyright (c) Microsoft Corporation.
# Licensed under the Apache License, Version 2.0
# (https://www.apache.org/licenses/LICENSE-2.0). See `NOTICE`.

module Crystalfaux
  # :nodoc:
  #
  # The functions that `Frame` and `ElementHandle` send with
  # `Runtime.callFunction`. They run in the frame's default world, which
  # Camoufox makes an isolated sandbox: they see the DOM, not the page's
  # globals. Each is one function expression; shared helpers are pasted in.
  module DomScripts
    # Whether text node *text* has a non-empty box (Playwright
    # `injected/domUtils.ts`, `isVisibleTextNode`). The box does not show
    # `visibility`; the caller checks the parent's style.
    HAS_TEXT_BOX = <<-JS
      const hasTextBox = text => {
        const range = text.ownerDocument.createRange();
        range.selectNode(text);
        const box = range.getBoundingClientRect();
        return box.width > 0 && box.height > 0;
      };
      JS

    # Playwright's `isElementVisible` (`injected/domUtils.ts`): rendered,
    # `visibility: visible`, and a non-empty box. An element with
    # `display: contents` has no box: it is visible when a child element is,
    # or when a text child has a box and the element's own `visibility`,
    # which its text inherits, is `visible`. A child element can override
    # an inherited `visibility: hidden`.
    IS_VISIBLE = <<-JS
      #{HAS_TEXT_BOX}
      const isVisible = el => {
        if (!el.isConnected) return false;
        const style = el.ownerDocument.defaultView.getComputedStyle(el);
        if (style.display === 'contents') {
          for (let child = el.firstChild; child; child = child.nextSibling) {
            if (child.nodeType === 1 && isVisible(child)) return true;
            if (child.nodeType === 3 && style.visibility === 'visible' && hasTextBox(child)) return true;
          }
          return false;
        }
        if (!el.checkVisibility() || style.visibility !== 'visible') return false;
        const box = el.getBoundingClientRect();
        return box.width > 0 && box.height > 0;
      };
      JS

    QUERY           = "selector => document.querySelector(selector)"
    QUERY_ALL       = "selector => Array.from(document.querySelectorAll(selector))"
    QUERY_UNDER     = "(root, selector) => root.querySelector(selector)"
    QUERY_ALL_UNDER = "(root, selector) => Array.from(root.querySelectorAll(selector))"

    TEXT_CONTENT = "el => el.textContent"
    INNER_TEXT   = <<-JS
      el => {
        if (typeof el.innerText !== 'string') throw new Error('Node is not an HTMLElement');
        return el.innerText;
      }
      JS
    ATTRIBUTE = "(el, name) => el.getAttribute(name)"
    VISIBLE   = "el => { #{IS_VISIBLE} return isVisible(el); }"

    # Returns the first element that *selector* matches when it is in
    # *state* (`attached` or `visible`), `true` when the page is in *state*
    # (`hidden` or `detached`), and `false` otherwise.
    WAIT_FOR_SELECTOR = <<-JS
      (selector, state) => {
        #{IS_VISIBLE}
        const el = document.querySelector(selector);
        const visible = !!el && isVisible(el);
        switch (state) {
          case 'attached': return el || false;
          case 'visible': return visible ? el : false;
          case 'hidden': return !visible;
          case 'detached': return !el;
        }
        throw new Error('Unknown state ' + state);
      }
      JS

    # The state checks before a click (Playwright `server/dom.ts`,
    # `_retryPointerAction`, and `injected/injectedScript.ts`,
    # `elementState`): attached, visible, and stable, which is the same box
    # in two animation frames in a row. Resolves to `"done"`,
    # `"notconnected"` or the name of the failed check.
    ACTIONABLE = <<-JS
      el => {
        #{IS_VISIBLE}
        if (!el.isConnected) return 'notconnected';
        if (!isVisible(el)) return 'element is not visible';
        const box = () => { const b = el.getBoundingClientRect(); return [b.x, b.y, b.width, b.height].join(); };
        const before = box();
        return new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(() => {
          if (!el.isConnected) return resolve('notconnected');
          resolve(box() === before ? 'done' : 'element is not stable');
        })));
      }
      JS

    # Whether a click at (*x*, *y*) in *el*'s document reaches *el* or a
    # descendant (Playwright `injected/injectedScript.ts`,
    # `expectHitTarget`). Returns `"done"`, or which element is on top.
    HIT_TEST = <<-JS
      const hitTest = (el, x, y) => {
        const root = el.getRootNode();
        const hit = (root.elementFromPoint ? root : el.ownerDocument).elementFromPoint(x, y);
        if (!hit) return 'element is outside of the viewport';
        for (let node = hit; node; node = node.parentNode || node.host) {
          if (node === el) return 'done';
        }
        let text = '<' + hit.localName;
        for (const name of ['id', 'class']) {
          const value = hit.getAttribute(name);
          if (value) text += ' ' + name + '="' + (value.length > 40 ? value.slice(0, 40) + '…' : value) + '"';
        }
        return 'covered by ' + text + '>';
      };
      JS

    # Hit-tests the element at (*x*, *y*) of its own frame's viewport: the
    # click point, mapped from the main frame's viewport. Returns
    # `HIT_TEST`'s result, or `"notconnected"`.
    HIT_TARGET = <<-JS
      (el, x, y) => {
        #{HIT_TEST}
        if (!el.isConnected) return 'notconnected';
        return hitTest(el, x, y);
      }
      JS

    # Hit-tests *iframe* at (*x*, *y*) of its own document's viewport
    # (Playwright `server/dom.ts`, `_checkFrameIsHitTarget`). Returns
    # `HIT_TEST`'s result, or `"notconnected"`.
    FRAME_HIT_TARGET = <<-JS
      (iframe, x, y) => {
        #{HIT_TEST}
        if (!iframe.isConnected) return 'notconnected';
        return hitTest(iframe, x, y);
      }
      JS

    # The border box of *iframe* before transforms, and the offset of the
    # child frame's viewport in it: the left and top border and padding
    # (Playwright `injected/injectedScript.ts`, `describeIFrameStyle`).
    FRAME_BOX = <<-JS
      iframe => {
        const style = iframe.ownerDocument.defaultView.getComputedStyle(iframe);
        const px = name => parseFloat(style[name]) || 0;
        const extra = style.boxSizing === 'border-box' ? [0, 0] : [
          px('borderLeftWidth') + px('paddingLeft') + px('paddingRight') + px('borderRightWidth'),
          px('borderTopWidth') + px('paddingTop') + px('paddingBottom') + px('borderBottomWidth'),
        ];
        return {
          width: px('width') + extra[0], height: px('height') + extra[1],
          left: px('borderLeftWidth') + px('paddingLeft'), top: px('borderTopWidth') + px('paddingTop'),
        };
      }
      JS

    # The elements of the frame's document, or of the subtree under *root*
    # when it is given, with ARIA role *role* and, when *name* is not
    # `null`, that accessible name (`exact`: equal after whitespace is
    # collapsed; otherwise a case-insensitive substring). *root* itself is
    # not a match. Hiddenness and names still look outside *root*, for
    # example at an `aria-hidden` ancestor or an `aria-labelledby` target.
    #
    # A small part of Playwright's `injected/roleUtils.ts`:
    #
    # - The role is the first token of the `role` attribute, else the
    #   implicit role for `button`, `link`, `dialog`, `checkbox` and
    #   `heading` (`getImplicitAriaRole`).
    # - Hidden elements are left out: under `aria-hidden="true"`, not
    #   rendered, or `visibility: hidden` (`isElementHiddenForAria`). An
    #   element with `display: contents` counts as rendered when a child
    #   element is, or a text child is and the element is `visibility:
    #   visible`.
    # - The name is the first non-empty of: `aria-labelledby` (the text of
    #   the referenced elements), `aria-label`, an input's value, `alt` or
    #   `<label>`, the content for name-from-content roles, and `title`.
    #   The content is the text of the visible descendants and the `alt` of
    #   images, with a space around each element that is not inline.
    #
    # Not done: roles other than those implicit roles (for example `list`
    # or `textbox` without a `role` attribute), shadow DOM, `aria-owns`,
    # `aria-describedby`, CSS generated content, the full name algorithm
    # for referenced and embedded controls, and ARIA role inheritance.
    BY_ROLE = <<-'JS'
      (role, name, exact, root = document) => {
        const implicitRoles = [
          ['button', 'button, input[type=button], input[type=submit], input[type=reset], input[type=image]'],
          ['link', 'a[href], area[href]'],
          ['dialog', 'dialog'],
          ['checkbox', 'input[type=checkbox]'],
          ['heading', 'h1, h2, h3, h4, h5, h6'],
        ];
        const nameFromContent = new Set(['button', 'cell', 'checkbox', 'columnheader', 'gridcell', 'heading',
          'link', 'menuitem', 'menuitemcheckbox', 'menuitemradio', 'option', 'radio', 'row', 'rowheader',
          'switch', 'tab', 'tooltip', 'treeitem']);
        const normalize = text => (text || '').replace(/\s+/g, ' ').trim();
        const roleOf = el => {
          const explicit = normalize(el.getAttribute('role')).split(' ')[0].toLowerCase();
          if (explicit) return explicit;
          const found = implicitRoles.find(([, selector]) => el.matches(selector));
          return found ? found[0] : null;
        };
        const hasTextBox = text => {
          const range = text.ownerDocument.createRange();
          range.selectNode(text);
          const box = range.getBoundingClientRect();
          return box.width > 0 && box.height > 0;
        };
        // An element with display: contents has no box of its own: it is
        // rendered when a child is (isElementHiddenForAria).
        const rendered = el => {
          const style = el.ownerDocument.defaultView.getComputedStyle(el);
          if (style.display !== 'contents' || el.localName === 'slot') return el.checkVisibility({visibilityProperty: true});
          for (let child = el.firstChild; child; child = child.nextSibling) {
            if (child.nodeType === 1 && !hidden(child)) return true;
            if (child.nodeType === 3 && style.visibility === 'visible' && hasTextBox(child)) return true;
          }
          return false;
        };
        const hidden = el => !!el.closest('[aria-hidden="true"]') || !rendered(el);
        const content = node => {
          let text = '';
          for (let child = node.firstChild; child; child = child.nextSibling) {
            if (child.nodeType === 3) { text += child.data; continue; }
            if (child.nodeType !== 1 || hidden(child)) continue;
            const inner = child.localName === 'img' ? (child.getAttribute('alt') || '') : content(child);
            const inline = child.ownerDocument.defaultView.getComputedStyle(child).display === 'inline';
            text += inline ? inner : ' ' + inner + ' ';
          }
          return text;
        };
        const accessibleName = (el, role) => {
          const root = el.getRootNode();
          const ids = normalize(el.getAttribute('aria-labelledby')).split(' ').filter(Boolean);
          const labelled = normalize(ids.map(id => root.getElementById(id)?.textContent || '').join(' '));
          if (labelled) return labelled;
          const label = normalize(el.getAttribute('aria-label'));
          if (label) return label;
          if (el.localName === 'input') {
            const type = (el.getAttribute('type') || '').toLowerCase();
            if (['button', 'submit', 'reset'].includes(type)) {
              return normalize(el.value) || {submit: 'Submit', reset: 'Reset'}[type] || '';
            }
            if (type === 'image') return normalize(el.getAttribute('alt'));
            const labels = normalize(Array.from(el.labels || [], l => l.textContent).join(' '));
            if (labels) return labels;
          }
          if (nameFromContent.has(role)) {
            const text = normalize(content(el));
            if (text) return text;
          }
          return normalize(el.getAttribute('title'));
        };
        const wanted = name === null ? null : normalize(name);
        const matches = candidate => wanted === null ||
          (exact ? candidate === wanted : candidate.toLowerCase().includes(wanted.toLowerCase()));
        return Array.from(root.querySelectorAll('*'))
          .filter(el => roleOf(el) === role && !hidden(el) && matches(accessibleName(el, role)));
      }
      JS
  end
end
