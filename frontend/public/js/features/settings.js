// "Chat features" settings — the per-device switches for the newer
// features: auto voice-to-text, message effects, translation language.

import { app, icon, openModal, prefs } from './core.js';
import { LANGUAGES, pickLanguage } from './ai-tools.js';

export function openFeatureSettings() {
  const langName = () => LANGUAGES.find(([c]) => c === prefs.get('translateTo'))?.[1] || 'English';
  const { box, close } = openModal(`
    <div class="feature-hero">
      <div class="feature-hero-icon">${icon('settings')}</div>
      <h3>Chat features</h3>
      <p>Settings for this device.</p>
    </div>
    <div class="settings-list">
      <label class="toggle-row">
        <span>
          <span class="toggle-title">🎤 Auto voice-to-text</span>
          <span class="toggle-sub">Show the text of voice messages under them automatically (uses your server's speech service)</span>
        </span>
        <input type="checkbox" class="switch" id="set-transcribe" ${prefs.get('autoTranscribe') ? 'checked' : ''}>
      </label>
      <label class="toggle-row">
        <span>
          <span class="toggle-title">🎉 Message effects</span>
          <span class="toggle-sub">Confetti, balloons and hearts for "Happy birthday", "Congratulations" and "Love you"</span>
        </span>
        <input type="checkbox" class="switch" id="set-effects" ${prefs.get('effects') ? 'checked' : ''}>
      </label>
      <button type="button" class="toggle-row as-button" id="set-lang">
        <span>
          <span class="toggle-title">🌐 Translate messages to</span>
          <span class="toggle-sub">Used by the Translate button on messages</span>
        </span>
        <span class="settings-value" id="set-lang-value">${langName()} ›</span>
      </button>
    </div>
    <div class="modal-actions"><button type="button" class="btn-primary" data-close>Done</button></div>`,
  { cardClass: 'feature-card' });

  box.querySelector('#set-transcribe').addEventListener('change', (e) => {
    prefs.set('autoTranscribe', e.target.checked);
    if (e.target.checked && app.state.activeId) app.renderMessages();
  });
  box.querySelector('#set-effects').addEventListener('change', (e) => prefs.set('effects', e.target.checked));
  box.querySelector('#set-lang').addEventListener('click', () => pickLanguage(() => {
    box.querySelector('#set-lang-value').textContent = `${langName()} ›`;
  }));
  box.querySelector('[data-close]').addEventListener('click', close);
}
