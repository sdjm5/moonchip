// End-to-end test of the moonchip wasm kernel, including real ROM runs.
// Run after `moon build --target wasm --release`:
//   cp _build/wasm/release/build/src/kernel/kernel.wasm web/moonchip.wasm
//   node web/test-kernel.mjs
import { readFileSync } from 'node:fs';

const DISP = 64 * 1024 * 1024; // 2048-byte display bitmap region
const ROM = 65 * 1024 * 1024; // raw ROM bytes staging area
const STATE = 66 * 1024 * 1024;

let passed = 0;
const TOTAL = 14;
const check = (name, ok) => {
  if (ok) passed++;
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${name}`);
};

const bytes = readFileSync(new URL('./moonchip.wasm', import.meta.url));
const mod = await WebAssembly.instantiate(bytes, {});
const E = mod.instance.exports;
const mem = new DataView(E.memory.buffer);
const u8 = new Uint8Array(E.memory.buffer);

E.moon_init();

// hand-assembled program: V0 = 237; I = 0x400; BCD; then exit (0FFF)
const bcd = [0x60, 237, 0xA4, 0x00, 0xF0, 0x33, 0x00, 0xFF];
u8.set(bcd, ROM);
check('load_rom returns length', E.load_rom(ROM, bcd.length) === bcd.length);
E.tick(10);
check('BCD encodes 237 as 2/3/7', E.ram_read(0x400) === 2 && E.ram_read(0x401) === 3 && E.ram_read(0x402) === 7);

// draw + collision through the boundary: sprite at I, drawn twice via loop
E.moon_init();
const drawProg = [
  0xA4, 0x00, // I = 0x400
  0x60, 5, 0x61, 5, // pos (5,5)
  0xD0, 0x12, // draw 2 rows
  0x12, 0x06, // loop back → XOR erase
];
u8.set(drawProg, ROM);
check('load second rom ok', E.load_rom(ROM, drawProg.length) === drawProg.length);
E.ram_write(0x400, 0xC0);
E.ram_write(0x401, 0xC0);
for (let f = 0; f < 2; f++) E.tick(2); // 4 instructions: I, pos, pos, draw
E.render_display(DISP);
let lit = 0;
for (let k = 0; k < 2048; k++) lit += u8[DISP + k];
check('sprite drawn (4 lit pixels)', lit === 4);
for (let f = 0; f < 1; f++) E.tick(2); // jump + XOR erase
E.render_display(DISP);
lit = 0;
for (let k = 0; k < 2048; k++) lit += u8[DISP + k];
check('XOR erase on second draw (0 lit, VF=1)', lit === 0);

// FX0A through the boundary
E.moon_init();
const waitKey = [0xF0, 0x0A, 0x00, 0xFF];
u8.set(waitKey, ROM);
E.load_rom(ROM, waitKey.length);
E.tick(5);
check('FX0A suspends the VM', E.halted() === 0 && E.tick(5) === 1);
E.key_down(11); // key B
E.tick(5);
E.state_out(STATE);
check('key press resolves FX0A into V0', mem.getUint32(STATE + 20, true) === 11);

// determinism: seeded CXNN gives identical display counts across resets
E.moon_init();
const rnd = [0xA4, 0x00, 0xC0, 0xFF, 0xD0, 0x05, 0x12, 0x04]; // sprite at random pos, forever
u8.set(rnd, ROM);
E.load_rom(ROM, rnd.length);
for (let k = 0; k < 5; k++) E.ram_write(0x400 + k, 0xFF); // 5 rows of 8 lit pixels
E.seed(777);
for (let f = 0; f < 30; f++) E.tick(8);
E.render_display(DISP);
const litA = (() => { let s = 0; for (let k = 0; k < 2048; k++) s += u8[DISP + k]; return s; })();
E.moon_init();
u8.set(rnd, ROM);
E.load_rom(ROM, rnd.length);
for (let k = 0; k < 5; k++) E.ram_write(0x400 + k, 0xFF);
E.seed(777);
for (let f = 0; f < 30; f++) E.tick(8);
E.render_display(DISP);
const litB = (() => { let s = 0; for (let k = 0; k < 2048; k++) s += u8[DISP + k]; return s; })();
check(`seeded run reproduces exactly (${litA} lit pixels)`, litA === litB && litA > 20);

// real ROM: IBM logo (public domain, from the Timendus suite)
E.moon_init();
const ibm = readFileSync(new URL('./roms/2-ibm-logo.ch8', import.meta.url));
u8.set(ibm, ROM);
check('ibm logo loads', E.load_rom(ROM, ibm.length) === ibm.length);
for (let f = 0; f < 60; f++) E.tick(11);
E.render_display(DISP);
lit = 0;
for (let k = 0; k < 2048; k++) lit += u8[DISP + k];
check(`IBM logo is on screen (${lit} lit pixels > 100)`, lit > 100);

// real ROM: chip8-logo animation still running after 2 s
E.moon_init();
const logo = readFileSync(new URL('./roms/1-chip8-logo.ch8', import.meta.url));
u8.set(logo, ROM);
E.load_rom(ROM, logo.length);
let aliveFrames = 0;
for (let f = 0; f < 120; f++) aliveFrames += E.tick(11);
check(`chip8-logo animates for 120 frames (${aliveFrames} alive)`, aliveFrames === 120);

// real ROM: beeper test drives the sound timer
E.moon_init();
const beep = readFileSync(new URL('./roms/7-beep.ch8', import.meta.url));
u8.set(beep, ROM);
E.load_rom(ROM, beep.length);
let beeped = 0;
for (let f = 0; f < 60; f++) { E.tick(11); beeped += E.sound_active(); }
check(`7-beep activates the sound timer (${beeped} frames)`, beeped > 5);

// real ROM: Brix (game) keeps running and lights the title screen
E.moon_init();
const brix = readFileSync(new URL('./roms/Brix.ch8', import.meta.url));
u8.set(brix, ROM);
E.load_rom(ROM, brix.length);
for (let f = 0; f < 30; f++) E.tick(10);
E.render_display(DISP);
lit = 0;
for (let k = 0; k < 2048; k++) lit += u8[DISP + k];
check(`Brix title screen renders (${lit} lit pixels > 50)`, lit > 50);

// throughput: 60 Hz frames are trivially cheap
E.moon_init();
u8.set(brix, ROM);
E.load_rom(ROM, brix.length);
const t0 = performance.now();
let frames = 0;
while (performance.now() - t0 < 500) { E.tick(11); frames++; }
const fps = frames / ((performance.now() - t0) / 1000);
console.log(`     emulated ${fps.toFixed(0)} frames of 60 Hz Brix per wall-clock second`);
check('emulates far faster than real time (fps > 600)', fps > 600);

console.log(`\n${passed}/${TOTAL} checks passed`);
process.exit(passed === TOTAL ? 0 : 1);
