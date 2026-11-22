// Runs in the browser. Buffer lines are logical blocks, not the browser's
// wrapped lines. Ranges keep Vim's text and Chromium's layout in agreement.
(() => {
  if (window !== window.top) return;
  const colors = new Set();
  let indexed = [], byNode = new WeakMap(), scrollY = 0, timer;
  const range = document.createRange();
  const controls = 'a[href],area,summary,button,input,textarea,select,label,video,audio,iframe,[contenteditable],[tabindex],[role="button"],[role="link"],[onclick]';

  function changed() {
    if (timer !== undefined) return;
    timer = setTimeout(() => {
      timer = undefined;
      globalThis.__pdfviewChanged?.();
    }, 32);
  }

  function watch() {
    const resize = new ResizeObserver(changed);
    resize.observe(document.documentElement);
    new MutationObserver(changed).observe(document.documentElement, {
      childList: true, subtree: true, characterData: true, attributes: true,
    });
    document.fonts.addEventListener('loadingdone', changed);
    document.addEventListener('load', changed, true);
    document.addEventListener('toggle', changed, true);
    document.addEventListener('scroll', (event) => {
      // Only browser-initiated root scrolling changes the logical viewport.
      // Nested scrolling changes the layout coordinates, even at the same top.
      if (event.target !== document || window.scrollY !== scrollY) changed();
    }, true);
  }
  document.addEventListener('DOMContentLoaded', watch, {once: true});

  const sheet = new CSSStyleSheet();
  document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];

  function scan() {
    indexed = [];
    byNode = new WeakMap();
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
      const entries = byNode.get(node);
      if (entries) entries.push(part);
      else byNode.set(node, [part]);
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

  function fragments(out, part, first, last, top) {
    if (!set(range, part, first, last)) return;
    let low = Infinity, high = -Infinity, row;
    for (const r of range.getClientRects()) {
      if (r.width === 0 || r.height === 0) continue;
      if (row !== undefined && Math.abs(r.top - row) > 0.5 && first + 1 < last) {
        const middle = (first + last) >> 1;
        fragments(out, part, first, middle, top);
        fragments(out, part, middle, last, top);
        return;
      }
      row = r.top;
      low = Math.min(low, r.top);
      high = Math.max(high, r.bottom);
    }
    if (low === Infinity) return;
    const prev = out.at(-1);
    if (prev && prev[1] === part.start + first && prev[2] === low + top && prev[3] === high + top) {
      prev[1] = part.start + last;
    } else {
      out.push([part.start + first, part.start + last, low + top, high + top]);
    }
  }

  function layout() {
    scan();
    const top = scrollY = window.scrollY;
    return {
      lines: indexed.map(({text}) => text),
      spans: indexed.map(({parts}) => {
        const out = [];
        for (const part of parts) fragments(out, part, 0, part.size, top);
        return out;
      }),
      total: document.scrollingElement?.scrollHeight ?? innerHeight,
      top,
      left: window.scrollX,
    };
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

  function boxes(chars) {
    return chars.map(([lnum, char]) => {
      const part = at(lnum, char);
      if (!part || !set(range, part, char - part.start, char - part.start + 1)) return null;
      const r = range.getBoundingClientRect();
      if (r.width === 0 || r.height === 0) return null;
      let {left, top, right, bottom} = r;
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
      if (left >= right || top >= bottom) return null;
      return [left + window.scrollX, top + window.scrollY, right + window.scrollX, bottom + window.scrollY];
    });
  }

  function hit({x, y}) {
    if (document.elementFromPoint(x, y)?.closest(controls)) return null;
    const caret = document.caretPositionFromPoint?.(x, y);
    const fallback = !caret && document.caretRangeFromPoint?.(x, y);
    const node = caret?.offsetNode ?? fallback?.startContainer;
    const col = caret?.offset ?? fallback?.startOffset;
    const parts = byNode.get(node);
    if (!parts) return null;
    for (const part of parts) {
      if (col < part.offset || col > part.end) continue;
      const delta = col - part.offset;
      let index = Math.min(part.size - 1, delta);
      if (part.offsets) {
        index = 0;
        while (index + 1 < part.size && part.offsets[index + 1] <= delta) index++;
      }
      return [part.line, part.start + index];
    }
    return null;
  }

  function frame({top, marks}) {
    window.scrollTo({left: window.scrollX, top, behavior: 'instant'});
    scrollY = window.scrollY;
    const highlights = new Map();
    let priority = 0;
    for (const {ranges, color} of marks) {
      let highlight = highlights.get(color);
      if (!highlight) {
        highlight = new Highlight();
        highlight.priority = ++priority;
        highlights.set(color, highlight);
      }
      for (const [lnum, first, last] of ranges) {
        const parts = indexed[lnum - 1]?.parts;
        if (!parts) continue;
        for (const part of parts) {
          if (part.start > last) break;
          const start = Math.max(0, first - part.start);
          const end = Math.min(part.size, last + 1 - part.start);
          if (start < end && set(range, part, start, end)) highlight.add(range.cloneRange());
        }
      }
    }
    for (const color of colors) {
      if (!highlights.has(color)) CSS.highlights.delete(`pdfview-${color}`);
    }
    for (const [color, highlight] of highlights) {
      if (!colors.has(color)) {
        const hex = color.toString(16).padStart(6, '0');
        sheet.insertRule(`::highlight(pdfview-${color}) { background-color: #${hex}c0; color: #172033; }`);
      }
      CSS.highlights.set(`pdfview-${color}`, highlight);
    }
    for (const color of highlights.keys()) colors.add(color);
    return scrollY;
  }

  globalThis.__pdfview = {layout, frame, boxes, hit};
})();
