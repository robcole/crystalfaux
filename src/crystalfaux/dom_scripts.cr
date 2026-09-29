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
    # Playwright's `isElementVisible` (`injected/domUtils.ts`): rendered,
    # `visibility: visible`, and a non-empty box. An element with
    # `display: contents` is visible when a child is.
    IS_VISIBLE = <<-JS
      const isVisible = el => {
        if (!el.isConnected) return false;
        const style = el.ownerDocument.defaultView.getComputedStyle(el);
        if (style.display === 'contents') {
          for (let child = el.firstChild; child; child = child.nextSibling) {
            if (child.nodeType === 1 && isVisible(child)) return true;
            if (child.nodeType === 3 && child.data.trim()) {
              const range = el.ownerDocument.createRange();
              range.selectNodeContents(child);
              const box = range.getBoundingClientRect();
              if (box.width > 0 && box.height > 0) return true;
            }
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

    # Whether a click at the centre of the element's first box reaches the
    # element or a descendant (Playwright `injected/injectedScript.ts`,
    # `expectHitTarget`). Returns `"done"`, or which element is on top. The
    # first box is the first quad that `Page.getContentQuads` reports, in
    # the element's own frame.
    HIT_TARGET = <<-JS
      el => {
        if (!el.isConnected) return 'notconnected';
        const boxes = el.getClientRects();
        if (!boxes.length) return 'element is not visible';
        const box = boxes[0];
        const x = box.left + box.width / 2, y = box.top + box.height / 2;
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
      }
      JS

    # The elements of the frame's document with ARIA role *role* and, when
    # *name* is not `null`, that accessible name (`exact`: equal after
    # whitespace is collapsed; otherwise a case-insensitive substring).
    #
    # A small part of Playwright's `injected/roleUtils.ts`:
    #
    # - The role is the first token of the `role` attribute, else the
    #   implicit role for `button`, `link`, `dialog`, `checkbox` and
    #   `heading` (`getImplicitAriaRole`).
    # - Hidden elements are left out: under `aria-hidden="true"`, not
    #   rendered, or `visibility: hidden` (`isElementHiddenForAria`).
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
      (role, name, exact) => {
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
        const hidden = el => !!el.closest('[aria-hidden="true"]') || !el.checkVisibility({visibilityProperty: true});
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
        return Array.from(document.querySelectorAll('*'))
          .filter(el => roleOf(el) === role && !hidden(el) && matches(accessibleName(el, role)));
      }
      JS
  end
end
