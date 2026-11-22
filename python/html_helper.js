// Runs in the browser. Buffer lines are logical blocks, not the browser's
// wrapped lines. Ranges keep Vim's text and Chromium's layout in agreement.
(() => {
  if (window !== window.top) return;
  let indexed = [];
  const range = document.createRange();
  const overrides = [];
  const sheet = new CSSStyleSheet();
  sheet.replaceSync(`@layer pdfview {
    *, *::before, *::after {
      animation: none !important;
      transition: none !important;
    }
    iframe, embed, object { display: none !important; }
    html { overflow-anchor: none !important; }
  }`);

  function freeze() {
    document.documentElement.inert = true;
    document.adoptedStyleSheets = [sheet, ...document.adoptedStyleSheets];
    for (const svg of document.querySelectorAll('svg')) svg.pauseAnimations();
    for (const marquee of document.querySelectorAll('marquee')) marquee.stop();
    for (const media of document.querySelectorAll('audio, video')) {
      media.autoplay = false;
      media.pause();
    }
  }

  async function settle() {
    // Re-evaluate position after reflow: a media query may no longer pin an element.
    for (const [style, name, value, priority] of overrides) style.setProperty(name, value, priority);
    overrides.length = 0;
    const pinned = [];
    for (const element of document.querySelectorAll('*')) {
      const css = getComputedStyle(element);
      if (css.position === 'fixed' || css.position === 'sticky') pinned.push([element.style, 'position', 'static']);
      if (css.contentVisibility === 'auto') pinned.push([element.style, 'content-visibility', 'visible']);
      if (css.backgroundAttachment.includes('fixed')) {
        pinned.push([element.style, 'background-attachment', css.backgroundAttachment.replaceAll('fixed', 'scroll')]);
      }
    }
    for (const [style, name, value] of pinned) {
      overrides.push([style, name, style.getPropertyValue(name), style.getPropertyPriority(name)]);
      style.setProperty(name, value, 'important');
    }
    for (const animation of document.getAnimations()) animation.cancel();
    window.scrollTo({left: 0, top: 0, behavior: 'instant'});
    // Decode offscreen and responsive images before the first strip can be cached.
    await Promise.all(Array.from(document.images, image => {
      if (image.loading === 'lazy') image.loading = 'eager';
      return image.decode().catch(() => {});
    }));
    await document.fonts.ready;
  }

  function scan() {
    indexed = [];
    let text = '', parts = [], count = 0, space;

    function line(empty = false) {
      if (parts.length || empty) indexed.push({text, parts});
      text = '';
      count = 0;
      parts = [];
      space = undefined;
    }

    function append(value, node, offset, end = offset + value.length) {
      // Store UTF-16 offsets only when they differ from code point offsets.
      let offsets, size = value.length;
      if (/[\uD800-\uDBFF]/.test(value)) {
        offsets = [0];
        for (const char of value) offsets.push(offsets.at(-1) + char.length);
        size = offsets.length - 1;
      }
      const part = {node, start: count, size, offset, end, offsets, line: indexed.length + 1};
      text += value;
      count += size;
      parts.push(part);
    }

    function add(node, mode) {
      const value = node.data;
      if (['pre', 'pre-wrap', 'break-spaces', 'preserve'].includes(mode)) {
        if (space && count) append(' ', ...space);
        space = undefined;
        let start = 0;
        for (const match of value.matchAll(/\r\n|[\r\n]/g)) {
          if (start < match.index) append(value.slice(start, match.index), node, start);
          line(true);
          start = match.index + match[0].length;
        }
        if (start < value.length) append(value.slice(start), node, start);
        return;
      }
      const keepBreaks = mode === 'pre-line' || mode === 'preserve-breaks';
      for (const {0: token, index} of value.matchAll(/[^ \t\r\n\f]+(?: [^ \t\r\n\f]+)*|[ \t\r\n\f]+/g)) {
        if (/^[ \t\r\n\f]/.test(token)) {
          if (keepBreaks && /[\r\n]/.test(token)) line();
          else if (count && !space) space = [node, index, index + token.length];
        } else {
          if (space) append(' ', ...space);
          space = undefined;
          append(token, node, index);
        }
      }
    }

    function walk(element) {
      const name = element.localName;
      if (['script', 'style', 'noscript', 'template', 'annotation', 'annotation-xml', 'textarea', 'select'].includes(name)) return;
      const css = getComputedStyle(element);
      const display = css.display;
      if (display === 'none' || css.contentVisibility === 'hidden') return;
      if (name === 'br') return line(true);
      const block = /^(?:block|flow-root|flex|grid|list-item|table(?:-row|-cell|-caption)?)$/.test(display);
      if (block) line();
      if (name === 'details' && !element.open) {
        const summary = Array.from(element.children).find((child) => child.localName === 'summary');
        if (summary) walk(summary);
      } else {
        for (const child of element.childNodes) {
          if (child.nodeType === Node.ELEMENT_NODE) walk(child);
          else if (child.nodeType === Node.TEXT_NODE && css.visibility === 'visible') add(child, css.whiteSpaceCollapse || css.whiteSpace);
        }
      }
      if (block) line();
    }

    if (document.body) walk(document.body);
    line();
  }

  function offset(part, index) {
    if (index === part.size) return part.end;
    return part.offset + (part.offsets ? part.offsets[index] : index);
  }

  function set(target, part, first, last) {
    if (!part.node.isConnected) return false;
    const end = offset(part, last);
    if (end > part.node.length) return false;
    target.setStart(part.node, offset(part, first));
    target.setEnd(part.node, end);
    return true;
  }

  function fragments(out, part, first, last) {
    if (!set(range, part, first, last)) return;
    let low = Infinity, high = -Infinity, row;
    for (const r of range.getClientRects()) {
      if (r.width === 0 || r.height === 0) continue;
      if (row !== undefined && Math.abs(r.top - row) > 0.5 && first + 1 < last) {
        const middle = (first + last) >> 1;
        fragments(out, part, first, middle);
        fragments(out, part, middle, last);
        return;
      }
      row = r.top;
      low = Math.min(low, r.top);
      high = Math.max(high, r.bottom);
    }
    if (low === Infinity) return;
    const prev = out.at(-1);
    if (prev && prev[1] === part.start + first && prev[2] === low && prev[3] === high) {
      prev[1] = part.start + last;
    } else {
      out.push([part.start + first, part.start + last, low, high]);
    }
  }

  async function layout() {
    await settle();
    scan();
    const root = document.scrollingElement;
    return {lines: indexed.map(({text}) => text), total: root.scrollHeight, wide: root.scrollWidth};
  }

  function geometry() {
    return indexed.map(({parts}) => {
      const out = [];
      for (const part of parts) fragments(out, part, 0, part.size);
      return out;
    });
  }

  function at(lnum, char) {
    const parts = indexed[lnum - 1]?.parts;
    if (!parts) return undefined;
    let low = 0, high = parts.length;
    while (low < high) {
      const mid = (low + high) >> 1;
      const part = parts[mid];
      if (char < part.start) high = mid;
      else if (char >= part.start + part.size) low = mid + 1;
      else return part;
    }
  }

  function clipRect(part, rect) {
    let {left, top, right, bottom} = rect;
    for (let e = part.node.parentElement; e && e !== document.body && e !== document.documentElement; e = e.parentElement) {
      const css = getComputedStyle(e);
      if (css.display === 'inline' || css.display === 'contents') continue;
      if (css.overflowX !== 'visible' || css.overflowY !== 'visible') {
        const b = e.getBoundingClientRect();
        if (css.overflowX !== 'visible') {
          left = Math.max(left, b.left + e.clientLeft);
          right = Math.min(right, b.left + e.clientLeft + e.clientWidth);
        }
        if (css.overflowY !== 'visible') {
          top = Math.max(top, b.top + e.clientTop);
          bottom = Math.min(bottom, b.top + e.clientTop + e.clientHeight);
        }
      }
    }
    return left < right && top < bottom ? [left, top, right, bottom] : null;
  }

  function boxes(chars) {
    return chars.map(([lnum, char]) => {
      const part = at(lnum, char);
      if (!part || !set(range, part, char - part.start, char - part.start + 1)) return null;
      return clipRect(part, range.getBoundingClientRect());
    });
  }

  function visitRanges(ranges, visit) {
    for (const [lnum, first, last] of ranges) {
      const parts = indexed[lnum - 1]?.parts;
      if (!parts) continue;
      for (const part of parts) {
        if (part.start > last) break;
        const start = Math.max(0, first - part.start);
        const end = Math.min(part.size, last + 1 - part.start);
        if (start < end && set(range, part, start, end)) visit(part);
      }
    }
  }

  function rectangles(ranges) {
    const boxes = [];
    visitRanges(ranges, part => {
      for (const rect of range.getClientRects()) {
        const box = clipRect(part, rect);
        if (box) boxes.push(box);
      }
    });
    return boxes;
  }

  globalThis.__pdfview = {freeze, layout, geometry, boxes, rectangles};
})();
