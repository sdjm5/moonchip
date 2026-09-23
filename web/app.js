// moonchip console UI.
//
// The whole VM lives in the MoonBit wasm module. Each animation frame the
// host runs one 60 Hz tick (N instructions + timer decay), copies the
// 64×32 display bitmap out of linear memory into an ImageData, and blits it
// scaled onto the canvas. Keypad events map straight onto exported calls;
// the beeper is a WebAudio square wave gated by the sound timer.

const DISP = 64 * 1024 * 1024; // display bitmap region (2048 bytes)
const ROM = 65 * 1024 * 1024; // ROM staging region
const STATE = 66 * 1024 * 1024; // debug state region (21 u32)

const E = (await WebAssembly.instantiate(
  await (await fetch('moonchip.wasm')).arrayBuffer(), {}
)).instance.exports;
E.moon_init();
const dispBytes = new Uint8Array(E.memory.buffer, DISP, 2048);
const romBytes = new Uint8Array(E.memory.buffer, ROM, 4096);

// ---------------------------------------------------------------------------
// display

const screen = document.getElementById('screen');
const sctx = screen.getContext('2d');
const off = document.createElement('canvas');
off.width = 64; off.height = 32;
const offctx = off.getContext('2d');
const img = offctx.createImageData(64, 32);

function blit() {
  for (let k = 0; k < 2048; k++) {
    const on = dispBytes[k] === 1;
    img.data[k * 4] = on ? 255 : 12;      // warm phosphor on dark green-gray
    img.data[k * 4 + 1] = on ? 179 : 14;
    img.data[k * 4 + 2] = on ? 71 : 11;
    img.data[k * 4 + 3] = 255;
  }
  offctx.putImageData(img, 0, 0);
  sctx.imageSmoothingEnabled = false;
  sctx.drawImage(off, 0, 0, screen.width, screen.height);
}

// ---------------------------------------------------------------------------
// ROM library

const ROMS = {
  test: [
    { file: '1-chip8-logo.ch8', name: '1 · chip8 logo', meta: '显示特性' },
    { file: '2-ibm-logo.ch8', name: '2 · IBM logo', meta: '经典' },
    { file: '3-corax+.ch8', name: '3 · Corax+', meta: '综合' },
    { file: '4-flags.ch8', name: '4 · flags', meta: '指令标志位' },
    { file: '5-quirks.ch8', name: '5 · quirks', meta: '怪癖判定' },
    { file: '6-keypad.ch8', name: '6 · keypad', meta: '键盘' },
    { file: '7-beep.ch8', name: '7 · beep', meta: '蜂鸣' },
  ],
  game: [
    { file: 'Brix.ch8', name: 'Brix', meta: '1990 打砖块' },
    { file: 'SpaceInvaders.ch8', name: 'Space Invaders', meta: 'David Winter' },
    { file: 'Blinky.ch8', name: 'Blinky', meta: '1991 吃豆' },
    { file: 'Pong.ch8', name: 'Pong', meta: '1P 网球' },
    { file: 'Tank.ch8', name: 'Tank', meta: '双人坦克' },
  ],
};

let currentRom = '';

async function loadRom(entry, btn) {
  const data = new Uint8Array(await (await fetch('roms/' + entry.file)).arrayBuffer());
  romBytes.set(data.subarray(0, 4096));
  const len = E.load_rom(ROM, Math.min(data.length, 4096));
  currentRom = entry.name;
  document.getElementById('rom-badge').textContent = entry.name;
  document.querySelectorAll('.roms button').forEach((b) => b.classList.toggle('on', b === btn));
  updateStateBadge();
  return len > 0;
}

function buildRomList(groupId, entries) {
  const host = document.getElementById(groupId);
  for (const entry of entries) {
    const b = document.createElement('button');
    b.innerHTML = `<span>${entry.name}</span><span class="meta">${entry.meta}</span>`;
    b.addEventListener('click', () => loadRom(entry, b));
    host.appendChild(b);
  }
}
buildRomList('roms-test', ROMS.test);
buildRomList('roms-game', ROMS.game);

// ---------------------------------------------------------------------------
// keypad

const KEY_ORDER = [0x1, 0x2, 0x3, 0xC, 0x4, 0x5, 0x6, 0xD, 0x7, 0x8, 0x9, 0xE, 0xA, 0x0, 0xB, 0xF];
const KEY_HOST = ['1', '2', '3', '4', 'q', 'w', 'e', 'r', 'a', 's', 'd', 'f', 'z', 'x', 'c', 'v'];
const keyEls = {};
const pad = document.getElementById('keypad');
KEY_ORDER.forEach((chipKey, idx) => {
  const el = document.createElement('div');
  el.className = 'k';
  el.innerHTML = `${chipKey.toString(16).toUpperCase()}<span class="g">${KEY_HOST[idx]}</span>`;
  el.dataset.chip = chipKey;
  pad.appendChild(el);
  keyEls[chipKey] = el;

  const press = (on) => {
    on ? E.key_down(chipKey) : E.key_up(chipKey);
    el.classList.toggle('down', on);
  };
  el.addEventListener('pointerdown', (e) => { e.preventDefault(); press(true); });
  el.addEventListener('pointerup', () => press(false));
  el.addEventListener('pointerleave', () => press(false));
});

const hostToChip = {};
KEY_HOST.forEach((h, i) => { hostToChip[h] = KEY_ORDER[i]; });

window.addEventListener('keydown', (e) => {
  const k = hostToChip[e.key.toLowerCase()];
  if (k === undefined || e.repeat) return;
  E.key_down(k);
  keyEls[k].classList.add('down');
  e.preventDefault();
});
window.addEventListener('keyup', (e) => {
  const k = hostToChip[e.key.toLowerCase()];
  if (k === undefined) return;
  E.key_up(k);
  keyEls[k].classList.remove('down');
});

// ---------------------------------------------------------------------------
// sound: square wave gated by the sound timer

let actx = null, osc = null, gain = null;
function ensureAudio() {
  if (actx) return;
  actx = new AudioContext();
  osc = actx.createOscillator();
  osc.type = 'square';
  osc.frequency.value = 240;
  gain = actx.createGain();
  gain.gain.value = 0;
  osc.connect(gain).connect(actx.destination);
  osc.start();
}
window.addEventListener('pointerdown', ensureAudio, { once: true });
window.addEventListener('keydown', ensureAudio, { once: true });

// ---------------------------------------------------------------------------
// controls

let ips = 11;
let paused = false;
let stepOnce = false;
document.getElementById('s-speed').addEventListener('input', (e) => {
  ips = Number(e.target.value);
  document.getElementById('v-speed').textContent = `${ips} inst/帧`;
});
document.getElementById('pause-btn').addEventListener('click', (e) => {
  paused = !paused;
  e.target.textContent = paused ? '▶ 继续' : '⏸ 暂停';
});
document.getElementById('step-btn').addEventListener('click', () => { stepOnce = true; });
document.getElementById('reset-btn').addEventListener('click', () => {
  E.reset();
  updateStateBadge();
});

const QUIRKS = [['q-vf', 0], ['q-mem', 1], ['q-shift', 2], ['q-clip', 3]];
for (const [id, qid] of QUIRKS) {
  document.getElementById(id).addEventListener('change', (e) => {
    E.set_quirk(qid, e.target.checked ? 1 : 0);
    updateStateBadge();
  });
}

function updateStateBadge() {
  document.getElementById('state-badge').textContent = E.halted() === 1
    ? 'HALTED（复位继续）'
    : paused ? 'PAUSED' : 'RUNNING';
}

// ---------------------------------------------------------------------------
// debug HUD

const dbg = document.getElementById('debug-out');
function renderDebug() {
  E.state_out(STATE);
  const s = new Uint32Array(E.memory.buffer, STATE, 21);
  const hex = (v, w) => v.toString(16).padStart(w, '0');
  let out = `pc=0${hex(s[0], 3)} i=${hex(s[1], 4)} sp=${s[2]} dt=${s[3]} st=${s[4]}\n`;
  for (let row = 0; row < 2; row++) {
    const cells = [];
    for (let k = 0; k < 8; k++) cells.push(`v${(row * 8 + k).toString(16)}=${hex(s[5 + row * 8 + k], 2)}`);
    out += cells.join(' ') + '\n';
  }
  out += `ops=${E.opcount()} sound=${E.sound_active() === 1 ? 'ON ' : 'off'} halted=${E.halted() === 1 ? 'yes' : 'no'}`;
  dbg.textContent = out;
}

// ---------------------------------------------------------------------------
// main loop (60 Hz)

let lastHud = 0;
setInterval(() => {
  if (!paused || stepOnce) {
    E.tick(ips);
    if (stepOnce) {
      stepOnce = false;
      paused = true;
      document.getElementById('pause-btn').textContent = '▶ 继续';
    }
  }
  E.render_display(DISP);
  blit();
  const soundOn = document.getElementById('sound-chk').checked && E.sound_active() === 1;
  if (gain) gain.gain.setTargetAtTime(soundOn ? 0.06 : 0, actx.currentTime, 0.005);
  updateStateBadge();
  const now = performance.now();
  if (now - lastHud > 150) {
    renderDebug();
    lastHud = now;
  }
}, 1000 / 60);

// auto-load the IBM logo so the page opens with something on screen
loadRom(ROMS.test[1], document.querySelectorAll('#roms-test button')[1]);
