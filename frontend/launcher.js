/* global Engine */
(() => {
  const button = document.getElementById('play');
  const status = document.getElementById('status');
  const progress = document.getElementById('progress');
  const canvas = document.getElementById('canvas');
  const launch = document.getElementById('launch');
  let started = false;
  // Invite links (…/?room=K7Q4MZ): the game joins that room once it has loaded.
  const invited = (new URLSearchParams(location.search).get('room') || '').toUpperCase().replace(/[^A-Z0-9]/g, '');
  if (/^[ABCDEFGHJKMNPQRSTUVWXYZ2-9]{6}$/.test(invited)) {
    button.firstChild.textContent = `Join room ${invited} `;
    status.textContent = 'Your friend invited you. Loading the game joins their room automatically.';
  }
  async function start() {
    if (started) { location.reload(); return; }
    started = true;
    button.disabled = true;
    window.BLIND_DRIVER_START_AI = false;
    progress.hidden = false;
    status.textContent = 'Loading the car, forest, and road…';
    try {
      if (!window.BLIND_DRIVER_CONFIG || typeof Engine === 'undefined') throw new Error('A game file did not load. Reload to try again.');
      const missing = Engine.getMissingFeatures({ threads: false });
      if (missing.length) throw new Error(`This browser is missing: ${missing.join(', ')}. Try an up-to-date desktop browser with WebGL 2 enabled.`);
      const engine = new Engine(window.BLIND_DRIVER_ENGINE_CONFIG);
      await engine.startGame({
        canvas,
        onProgress(current, total) {
          if (total > 0) { progress.max = total; progress.value = current; }
          else progress.removeAttribute('value');
        },
        onExit(code) {
          canvas.hidden = true;
          launch.hidden = false;
          button.disabled = false;
          button.textContent = 'Reload game ↗';
          progress.hidden = true;
          status.textContent = code ? 'The game stopped. Reload to try again.' : 'The ride has ended.';
        },
      });
      launch.hidden = true;
      canvas.hidden = false;
      canvas.focus();
      // Audio starts/resumes on the next game interaction if the download outlasted
      // the browser's initial user-activation window.
    } catch (error) {
      console.error(error);
      status.textContent = error.message || String(error);
      progress.hidden = true;
      button.textContent = 'Retry loading ↗';
      button.disabled = false;
    }
  }
  button.addEventListener('click', start);
  window.addEventListener('keydown', event => {
    if (!canvas.hidden && ['Tab', ' ', 'ArrowUp', 'ArrowDown', 'ArrowLeft', 'ArrowRight'].includes(event.key)) event.preventDefault();
  });
})();
