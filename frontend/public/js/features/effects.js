// Message effects — "Happy birthday" brings balloons and confetti,
// "Congratulations" confetti, "Love you" hearts. Plays once when the
// message is sent or arrives live, never when scrolling through history.

import { prefs } from './core.js';

const RULES = [
  { re: /\b(happy\s*b(irth)?day|hbd)\b|🎂|🎈/i, effect: 'birthday' },
  { re: /\bhappy\s*new\s*year\b|🎆|🎇/i, effect: 'confetti' },
  { re: /\b(congrat(s|ulations)?|well done|great job|proud of you)\b|🎉|🥳|🎊/i, effect: 'confetti' },
  { re: /\b(i\s*)?love\s*(you|u)\b|\bmiss\s*(you|u)\b|❤️|😍|🥰|💕|💖/i, effect: 'hearts' },
];

export function effectFor(text) {
  if (typeof text !== 'string') return null;
  return RULES.find((r) => r.re.test(text))?.effect || null;
}

let running = false;

export function maybePlayEffect(text) {
  if (!prefs.get('effects')) return;
  if (window.matchMedia?.('(prefers-reduced-motion: reduce)').matches) return;
  const effect = effectFor(text);
  if (effect && !running) play(effect);
}

function play(effect) {
  running = true;
  const canvas = document.createElement('canvas');
  canvas.className = 'effects-canvas';
  document.body.appendChild(canvas);
  const ctx = canvas.getContext('2d');
  const dpr = window.devicePixelRatio || 1;
  const resize = () => {
    canvas.width = innerWidth * dpr;
    canvas.height = innerHeight * dpr;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  };
  resize();

  const W = innerWidth, H = innerHeight;
  const colors = ['#FF6B6B', '#FDCB6E', '#2EE6A6', '#6FA1FF', '#E84393', '#A29BFE', '#00C2FF'];
  const parts = [];
  const rnd = (a, b) => a + Math.random() * (b - a);

  if (effect === 'confetti' || effect === 'birthday') {
    for (let i = 0; i < 160; i++) {
      parts.push({
        kind: 'confetti', x: rnd(0, W), y: rnd(-H * 0.6, -10), vx: rnd(-1.5, 1.5), vy: rnd(2, 5.5),
        rot: rnd(0, Math.PI), vr: rnd(-0.2, 0.2), w: rnd(6, 11), h: rnd(8, 15), color: colors[i % colors.length],
      });
    }
  }
  if (effect === 'birthday') {
    for (let i = 0; i < 14; i++) {
      parts.push({
        kind: 'balloon', x: rnd(30, W - 30), y: H + rnd(20, 300), vx: 0, vy: -rnd(1.6, 3), sway: rnd(0, 6),
        r: rnd(18, 28), color: colors[i % colors.length],
      });
    }
  }
  if (effect === 'hearts') {
    for (let i = 0; i < 40; i++) {
      parts.push({
        kind: 'heart', x: rnd(0, W), y: H + rnd(10, 400), vx: rnd(-0.5, 0.5), vy: -rnd(1.5, 3.8),
        size: rnd(14, 34), sway: rnd(0, 6), color: ['#FF6B81', '#E84393', '#FF8FA3'][i % 3],
      });
    }
  }

  const heart = (x, y, s, color) => {
    ctx.fillStyle = color;
    ctx.beginPath();
    ctx.moveTo(x, y + s * 0.3);
    ctx.bezierCurveTo(x, y, x - s / 2, y, x - s / 2, y + s * 0.3);
    ctx.bezierCurveTo(x - s / 2, y + s * 0.6, x, y + s * 0.8, x, y + s);
    ctx.bezierCurveTo(x, y + s * 0.8, x + s / 2, y + s * 0.6, x + s / 2, y + s * 0.3);
    ctx.bezierCurveTo(x + s / 2, y, x, y, x, y + s * 0.3);
    ctx.fill();
  };

  const started = performance.now();
  const DURATION = 3200;
  const frame = (now) => {
    const t = now - started;
    ctx.clearRect(0, 0, W, H);
    const fade = t > DURATION - 600 ? Math.max(0, (DURATION - t) / 600) : 1;
    ctx.globalAlpha = fade;
    for (const p of parts) {
      p.x += p.vx + (p.sway ? Math.sin((t / 400) + p.sway) * 0.6 : 0);
      p.y += p.vy;
      if (p.kind === 'confetti') {
        p.rot += p.vr;
        ctx.save();
        ctx.translate(p.x, p.y);
        ctx.rotate(p.rot);
        ctx.fillStyle = p.color;
        ctx.fillRect(-p.w / 2, -p.h / 2, p.w, p.h * Math.abs(Math.cos(p.rot * 2)));
        ctx.restore();
      } else if (p.kind === 'balloon') {
        ctx.strokeStyle = 'rgba(255,255,255,0.5)';
        ctx.beginPath(); ctx.moveTo(p.x, p.y + p.r); ctx.lineTo(p.x + Math.sin(t / 300) * 4, p.y + p.r + 40); ctx.stroke();
        ctx.fillStyle = p.color;
        ctx.beginPath(); ctx.ellipse(p.x, p.y, p.r * 0.85, p.r, 0, 0, Math.PI * 2); ctx.fill();
        ctx.fillStyle = 'rgba(255,255,255,0.35)';
        ctx.beginPath(); ctx.ellipse(p.x - p.r * 0.3, p.y - p.r * 0.35, p.r * 0.18, p.r * 0.3, -0.5, 0, Math.PI * 2); ctx.fill();
      } else {
        heart(p.x, p.y, p.size, p.color);
      }
    }
    if (t < DURATION) requestAnimationFrame(frame);
    else { canvas.remove(); running = false; }
  };
  requestAnimationFrame(frame);
}
