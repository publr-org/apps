// The page's half of `native`'s web backend (`app.zig`): it runs an app built for
// wasm32-wasi on a canvas. WASI's files are `publr-files.js` (kept in OPFS under `folder`),
// the app's frames are put on the canvas, and the canvas's events go in as the app's.
//
//   const app = await NativeApp.start({ canvas, module: 'publr-desktop.wasm', folder: 'publr-desktop' });
//   app.onTitle = (title) => ...;

const NativeApp = (() => {
  const cursors = ['default', 'pointer', 'text', 'grab', 'grabbing', 'crosshair'];
  const key_codes = {
    Enter: 0, Tab: 1, ' ': 2, Backspace: 3, Escape: 4, Delete: 5, ArrowLeft: 6, ArrowRight: 7,
    ArrowUp: 8, ArrowDown: 9, Home: 10, End: 11, PageUp: 12, PageDown: 13,
  };
  // `TextCommand`, in its order.
  const command = {
    delete_backward: 0, delete_forward: 1, delete_word_backward: 2, delete_to_start: 3, left: 4,
    right: 5, word_left: 6, word_right: 7, start: 8, end: 9, select_left: 10, select_right: 11,
    select_word_left: 12, select_word_right: 13, select_to_start: 14, select_to_end: 15,
    select_all: 16, enter: 17, tab: 18, backtab: 19, escape: 20, copy: 21, cut: 22, paste: 23,
  };

  class Exit extends Error {}

  function mods_of(event) {
    return (event.shiftKey ? 1 : 0) | (event.ctrlKey ? 2 : 0) | (event.altKey ? 4 : 0) | (event.metaKey ? 8 : 0);
  }

  // The editing key a key press means while the app takes text, as macOS binds them.
  function text_command(event) {
    const shift = event.shiftKey;
    const word = event.altKey;
    const line = event.metaKey;
    switch (event.key) {
      case 'Backspace': return line ? command.delete_to_start : word ? command.delete_word_backward : command.delete_backward;
      case 'Delete': return command.delete_forward;
      case 'ArrowLeft':
        if (line) return shift ? command.select_to_start : command.start;
        if (word) return shift ? command.select_word_left : command.word_left;
        return shift ? command.select_left : command.left;
      case 'ArrowRight':
        if (line) return shift ? command.select_to_end : command.end;
        if (word) return shift ? command.select_word_right : command.word_right;
        return shift ? command.select_right : command.right;
      case 'Home': return shift ? command.select_to_start : command.start;
      case 'End': return shift ? command.select_to_end : command.end;
      case 'Enter': return command.enter;
      case 'Tab': return shift ? command.backtab : command.tab;
      case 'Escape': return command.escape;
    }
    if (line && event.key === 'a') return command.select_all;
    if (line && event.key === 'c') return command.copy;
    if (line && event.key === 'x') return command.cut;
    if (line && event.key === 'v') return command.paste;
    return null;
  }

  async function start({ canvas, module, folder }) {
    const context = canvas.getContext('2d');
    const encoder = new TextEncoder();
    const decoder = new TextDecoder();
    let instance = null;
    let text_input = false;
    const app = { onTitle: () => {}, onOpen: (url) => window.open(url, '_blank', 'noopener') };

    const memory = () => instance.exports.memory;
    const bytes = (ptr, len) => new Uint8Array(memory().buffer, ptr, len);
    const string = (ptr, len) => decoder.decode(bytes(ptr, len));

    // The app's arguments and environment: `HOME` is the files' folder, `.`.
    const args = ['app'];
    const environ = ['HOME=.'];
    const strings = (list, count_out, size_out) => {
      const view = new DataView(memory().buffer);
      view.setUint32(count_out, list.length, true);
      view.setUint32(size_out, list.reduce((sum, each) => sum + encoder.encode(each).length + 1, 0), true);
      return 0;
    };
    const fill = (list, pointers, buffer) => {
      const view = new DataView(memory().buffer);
      let at = buffer;
      list.forEach((each, index) => {
        const encoded = encoder.encode(each);
        view.setUint32(pointers + index * 4, at, true);
        bytes(at, encoded.length).set(encoded);
        bytes(at + encoded.length, 1)[0] = 0;
        at += encoded.length + 1;
      });
      return 0;
    };

    // What the app prints goes to the console, a line at a time.
    const lines = { 1: '', 2: '' };
    const files = PublrFiles;
    const wasi = {
      ...files.wasi,
      args_sizes_get: (count, size) => strings(args, count, size),
      args_get: (pointers, buffer) => fill(args, pointers, buffer),
      environ_sizes_get: (count, size) => strings(environ, count, size),
      environ_get: (pointers, buffer) => fill(environ, pointers, buffer),
      clock_time_get(id, precision, out) {
        const now = id === 0 ? BigInt(Date.now()) * 1000000n : BigInt(Math.round(performance.now() * 1e6));
        new DataView(memory().buffer).setBigUint64(out, now, true);
        return 0;
      },
      clock_res_get(id, out) {
        new DataView(memory().buffer).setBigUint64(out, 1000n, true);
        return 0;
      },
      random_get(ptr, len) {
        crypto.getRandomValues(bytes(ptr, len));
        return 0;
      },
      // One thread: waiting is not done here, the page's next frame comes instead.
      poll_oneoff: () => 52,
      fd_sync: () => 0,
      path_link: () => 52,
      path_symlink: () => 52,
      path_readlink: () => 52,
      path_filestat_set_times: () => 0,
      fd_filestat_set_times: () => 0,
      proc_exit(code) { throw new Exit(String(code)); },
      fd_write(fd, iovs, count, written_out) {
        if (fd !== 1 && fd !== 2) return files.wasi.fd_write(fd, iovs, count, written_out);
        const view = new DataView(memory().buffer);
        let total = 0;
        for (let index = 0; index < count; index += 1) {
          const ptr = view.getUint32(iovs + index * 8, true);
          const len = view.getUint32(iovs + index * 8 + 4, true);
          lines[fd] += string(ptr, len);
          total += len;
        }
        const parts = lines[fd].split('\n');
        lines[fd] = parts.pop();
        for (const line of parts) (fd === 2 ? console.warn : console.log)(line);
        view.setUint32(written_out, total, true);
        return 0;
      },
    };

    const page = {
      present(ptr, len, width, height) {
        if (canvas.width !== width || canvas.height !== height) {
          canvas.width = width;
          canvas.height = height;
        }
        const pixels = new Uint8ClampedArray(memory().buffer, ptr, len);
        context.putImageData(new ImageData(new Uint8ClampedArray(pixels), width, height), 0, 0);
      },
      set_cursor: (cursor) => { canvas.style.cursor = cursors[cursor] ?? 'default'; },
      set_title: (ptr, len) => app.onTitle(string(ptr, len)),
      open_url: (ptr, len) => app.onOpen(string(ptr, len)),
      text_input: (on) => { text_input = on; },
      // The page draws a frame on every display refresh: work queued for one waits for it.
      wake: () => {},
    };

    const response = await fetch(module);
    if (!response.ok) throw new Error(`${module} could not be fetched: ${response.status}`);
    ({ instance } = await WebAssembly.instantiateStreaming(response, {
      wasi_snapshot_preview1: wasi,
      desktop: page,
    }));
    const storage = async () => (await navigator.storage.getDirectory()).getDirectoryHandle(folder, { create: true });
    await files.load(memory, null, storage);

    const resize = () => {
      const box = canvas.getBoundingClientRect();
      instance.exports.desktop_resize(box.width, box.height, devicePixelRatio);
    };

    // The app sets itself up and returns from `main`: the page runs its loop from here.
    try {
      resize();
      instance.exports._start();
    } catch (error) {
      if (!(error instanceof Exit) || error.message !== '0') throw error;
    }
    resize();
    new ResizeObserver(resize).observe(canvas);

    const at = (event) => {
      const box = canvas.getBoundingClientRect();
      return [event.clientX - box.left, event.clientY - box.top];
    };
    const exports = instance.exports;

    canvas.tabIndex = 0;
    canvas.addEventListener('pointerdown', (event) => {
      canvas.focus();
      canvas.setPointerCapture(event.pointerId);
      exports.desktop_mouse(0, ...at(event), event.button, event.detail || 1, mods_of(event));
    });
    canvas.addEventListener('pointerup', (event) => {
      exports.desktop_mouse(1, ...at(event), event.button, event.detail || 1, mods_of(event));
    });
    canvas.addEventListener('pointermove', (event) => {
      exports.desktop_mouse(event.buttons ? 3 : 2, ...at(event), 0, 1, mods_of(event));
    });
    canvas.addEventListener('pointerleave', () => {
      exports.desktop_mouse(4, 0, 0, 0, 0, 0);
    });
    canvas.addEventListener('contextmenu', (event) => event.preventDefault());
    canvas.addEventListener('wheel', (event) => {
      event.preventDefault();
      const precise = event.deltaMode === 0;
      const step = precise ? 1 : 16;
      exports.desktop_scroll(...at(event), -event.deltaX * step, -event.deltaY * step, precise, mods_of(event));
    }, { passive: false });
    canvas.addEventListener('focus', () => { exports.desktop_focus(true); });
    canvas.addEventListener('blur', () => { exports.desktop_focus(false); });

    const send_text = (text) => {
      const encoded = encoder.encode(text).slice(0, 256);
      bytes(exports.desktop_text_buffer(), encoded.length).set(encoded);
      return encoded.length;
    };
    canvas.addEventListener('keydown', (event) => {
      const code = key_codes[event.key] ?? 14;
      const typed = event.key.length === 1 && !event.metaKey && !event.ctrlKey ? event.key : '';
      if (text_input) {
        const editing = text_command(event);
        if (editing !== null) {
          event.preventDefault();
          exports.desktop_text_command(editing);
          return;
        }
        if (typed) {
          event.preventDefault();
          exports.desktop_text(send_text(typed));
          return;
        }
      }
      if (event.metaKey && event.key === 'r') return;
      event.preventDefault();
      exports.desktop_key(true, code, mods_of(event), send_text(event.key.length === 1 ? event.key : ''), event.repeat);
    });
    canvas.addEventListener('keyup', (event) => {
      const code = key_codes[event.key] ?? 14;
      exports.desktop_key(false, code, mods_of(event), send_text(event.key.length === 1 ? event.key : ''), false);
    });

    // A frame on every display refresh, as the system's display link gives one: the app
    // draws when something changed.
    const tick = () => {
      exports.desktop_frame();
      files.flush();
      requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
    return app;
  }

  return { start };
})();
