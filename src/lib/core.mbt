// CHIP-8 virtual machine.
//
// A faithful COSMAC-VIP-flavoured CHIP-8: 4 KB RAM, sixteen 8-bit registers,
// a 64×32 1-bit display, a 16-level stack, delay/sound timers and the font
// at 0x50. The famous peripheral differences between the original hardware
// and later SUPER-CHIP are modelled as quirk switches (VF reset on logic
// ops, I increment on FX55/FX65, shift operand, sprite clipping) so the
// Timendus test suite can be run against any combination.
//
// The VM is fully deterministic: randomness comes from an internal xorshift
// PRNG that the host seeds, so a given ROM + inputs replays exactly.

///|
pub const MEM_SIZE : Int = 4096

///|
pub const DISP_W : Int = 64

///|
pub const DISP_H : Int = 32

///|
pub const ROM_BASE : Int = 0x200

///|
pub const FONT_ADDR : Int = 0x50

///|
pub(all) struct Chip8 {
  mem : FixedArray[Byte]
  v : FixedArray[Int] // V0..VF
  mut i : Int
  mut pc : Int
  stack : FixedArray[Int]
  mut sp : Int
  disp : FixedArray[Byte] // 64*32, 1 = lit
  keys : FixedArray[Bool] // 16 keys
  mut dt : Int // delay timer
  mut st : Int // sound timer
  mut waiting : Bool // FX0A: halted until a key press
  mut drew : Bool // display touched since last frame
  mut halted : Bool // unknown opcode / stack overflow → stop
  mut msg : String // halt reason (debug)
  // quirks
  mut quirk_vf_reset : Bool // 8XY1/2/3 clear VF first (original: on)
  mut quirk_memory : Bool // FX55/FX65 leave I incremented (original: on)
  mut quirk_shift : Bool // 8XY6/8XYE shift VY into VX (original: on)
  mut quirk_clip : Bool // sprites clip at screen edges (original: on)
  // deterministic randomness
  mut rng : Int
  // stats
  mut opcount : Int
}

///|
let font_data : FixedArray[Int] = FixedArray::from_array([
  0xF0, 0x90, 0x90, 0x90, 0xF0, // 0
   0x20, 0x60, 0x20, 0x20, 0x70, // 1
   0xF0, 0x10, 0xF0, 0x80, 0xF0, // 2
   0xF0, 0x10, 0xF0, 0x10, 0xF0, // 3
   0x90, 0x90, 0xF0, 0x10, 0x10, // 4
   0xF0, 0x80, 0xF0, 0x10, 0xF0, // 5
   0xF0, 0x80, 0xF0, 0x90, 0xF0, // 6
   0xF0, 0x10, 0x20, 0x40, 0x40, // 7
   0xF0, 0x90, 0xF0, 0x90, 0xF0, // 8
   0xF0, 0x90, 0xF0, 0x10, 0xF0, // 9
   0xF0, 0x90, 0xF0, 0x90, 0x90, // A
   0xE0, 0x90, 0xE0, 0x90, 0xE0, // B
   0xF0, 0x80, 0x80, 0x80, 0xF0, // C
   0xE0, 0x90, 0x90, 0x90, 0xE0, // D
   0xF0, 0x80, 0xF0, 0x80, 0xF0, // E
   0xF0, 0x80, 0xF0, 0x80, 0x80, // F
])

///|
pub fn Chip8::new() -> Chip8 {
  let c = {
    mem: FixedArray::make(MEM_SIZE, 0),
    v: FixedArray::make(16, 0),
    i: 0,
    pc: ROM_BASE,
    stack: FixedArray::make(16, 0),
    sp: 0,
    disp: FixedArray::make(DISP_W * DISP_H, 0),
    keys: FixedArray::make(16, false),
    dt: 0,
    st: 0,
    waiting: false,
    drew: false,
    halted: false,
    msg: "",
    quirk_vf_reset: true,
    quirk_memory: false,
    quirk_shift: true,
    quirk_clip: true,
    rng: 0x9E3779B9,
    opcount: 0,
  }
  for k = 0; k < 80; k = k + 1 {
    c.mem[FONT_ADDR + k] = font_data[k].to_byte()
  }
  c
}

///|
/// Full reset: memory contents beyond the font survive (like a fresh boot
/// with the same tape inserted), registers, stack, display and timers clear.
pub fn Chip8::reset(self : Chip8) -> Unit {
  self.i = 0
  self.pc = ROM_BASE
  self.sp = 0
  self.dt = 0
  self.st = 0
  self.waiting = false
  self.drew = false
  self.halted = false
  self.msg = ""
  self.opcount = 0
  for k = 0; k < 16; k = k + 1 {
    self.v[k] = 0
    self.keys[k] = false
  }
  for k = 0; k < DISP_W * DISP_H; k = k + 1 {
    self.disp[k] = 0
  }
}

///|
/// Copy a ROM into memory at 0x200. Returns the length loaded, or -1 when
/// it does not fit.
pub fn Chip8::load_rom(self : Chip8, rom : FixedArray[Byte]) -> Int {
  let len = rom.length()
  if ROM_BASE + len > MEM_SIZE {
    return -1
  }
  for k = 0; k < len; k = k + 1 {
    self.mem[ROM_BASE + k] = rom[k]
  }
  len
}

///|
/// Seed the PRNG (xorshift32).
pub fn Chip8::seed(self : Chip8, s : Int) -> Unit {
  self.rng = if s == 0 { 0x9E3779B9 } else { s }
}

///|
fn Chip8::rand8(self : Chip8) -> Int {
  let mut x = self.rng
  x = x ^ (x << 13)
  x = x ^ (x >> 17)
  x = x ^ (x << 5)
  self.rng = x
  (x >> 24) & 0xFF
}

///|
/// Key state from the host.
pub fn Chip8::key_down(self : Chip8, k : Int) -> Unit {
  if k >= 0 && k < 16 {
    self.keys[k] = true
    if self.waiting {
      // FX0A resolves on the next instruction fetch
      self.waiting = false
    }
  }
}

///|
pub fn Chip8::key_up(self : Chip8, k : Int) -> Unit {
  if k >= 0 && k < 16 {
    self.keys[k] = false
  }
}

///|
/// Decrement delay/sound timers — call at 60 Hz.
pub fn Chip8::tick_timers(self : Chip8) -> Unit {
  if self.dt > 0 {
    self.dt = self.dt - 1
  }
  if self.st > 0 {
    self.st = self.st - 1
  }
}

///|
/// Execute one instruction. Returns false when the VM has halted.
pub fn Chip8::step(self : Chip8) -> Bool {
  if self.halted {
    return false
  }
  if self.pc < 0 || self.pc + 1 >= MEM_SIZE {
    self.halt("pc out of range")
    return false
  }
  if self.waiting {
    // FX0A: hold the PC until any key is pressed
    let mut any = false
    for k = 0; k < 16; k = k + 1 {
      if self.keys[k] {
        any = true
      }
    }
    if !any {
      return true
    }
    self.waiting = false
  }
  let hi = self.mem[self.pc].to_int()
  let lo = self.mem[self.pc + 1].to_int()
  let op = hi * 256 + lo
  let x = (op >> 8) & 0xF
  let y = (op >> 4) & 0xF
  let nn = op & 0xFF
  let nnn = op & 0xFFF
  self.pc = self.pc + 2
  self.opcount = self.opcount + 1
  match hi >> 4 {
    0x00 =>
      if op == 0x00E0 {
        // CLS
        for k = 0; k < DISP_W * DISP_H; k = k + 1 {
          self.disp[k] = 0
        }
        self.drew = true
      } else if op == 0x00EE {
        // RET
        if self.sp == 0 {
          self.halt("stack underflow")
          return false
        }
        self.sp = self.sp - 1
        self.pc = self.stack[self.sp]
      } else if op == 0x00FD {
        // 00FD: exit interpreter (test suites finish cleanly this way)
        self.halt("exit")
        return false
      }
    // 0NNN (machine code call) ignored
    0x01 => self.pc = nnn
    0x02 => {
      if self.sp >= 16 {
        self.halt("stack overflow")
        return false
      }
      self.stack[self.sp] = self.pc
      self.sp = self.sp + 1
      self.pc = nnn
    }
    0x03 => if self.v[x] == nn { self.pc = self.pc + 2 }
    0x04 => if self.v[x] != nn { self.pc = self.pc + 2 }
    0x05 =>
      if (op & 0xF) == 0 {
        if self.v[x] == self.v[y] {
          self.pc = self.pc + 2
        }
      } else {
        self.halt("bad 5XY_ opcode")
        return false
      }
    0x06 => self.v[x] = nn
    0x07 => self.v[x] = (self.v[x] + nn) & 0xFF
    0x08 => {
      let vx = self.v[x]
      let vy = self.v[y]
      match op & 0xF {
        0 => self.v[x] = vy
        1 => {
          if self.quirk_vf_reset {
            self.v[0xF] = 0
          }
          self.v[x] = (vx | vy) & 0xFF
        }
        2 => {
          if self.quirk_vf_reset {
            self.v[0xF] = 0
          }
          self.v[x] = vx & vy & 0xFF
        }
        3 => {
          if self.quirk_vf_reset {
            self.v[0xF] = 0
          }
          self.v[x] = (vx ^ vy) & 0xFF
        }
        4 => {
          let sum = vx + vy
          self.v[x] = sum & 0xFF
          self.v[0xF] = if sum > 0xFF { 1 } else { 0 }
        }
        5 => {
          self.v[x] = (vx - vy) & 0xFF
          self.v[0xF] = if vx >= vy { 1 } else { 0 }
        }
        6 =>
          if self.quirk_shift {
            self.v[x] = (vy >> 1) & 0xFF
            self.v[0xF] = vy & 1
          } else {
            self.v[x] = (vx >> 1) & 0xFF
            self.v[0xF] = vx & 1
          }
        7 => {
          self.v[x] = (vy - vx) & 0xFF
          self.v[0xF] = if vy >= vx { 1 } else { 0 }
        }
        14 =>
          if self.quirk_shift {
            self.v[x] = (vy << 1) & 0xFF
            self.v[0xF] = (vy >> 7) & 1
          } else {
            self.v[x] = (vx << 1) & 0xFF
            self.v[0xF] = (vx >> 7) & 1
          }
        _ => {
          self.halt("bad 8XY_ opcode")
          return false
        }
      }
    }
    0x09 =>
      if (op & 0xF) == 0 {
        if self.v[x] != self.v[y] {
          self.pc = self.pc + 2
        }
      } else {
        self.halt("bad 9XY_ opcode")
        return false
      }
    0x0A => self.i = nnn
    0x0B => self.pc = nnn + self.v[0]
    0x0C => self.v[x] = self.rand8() & nn
    0x0D => self.draw_sprite(x, y, nnn & 0xF)
    0x0E =>
      if nn == 0x9E {
        if self.keys[self.v[x] & 0xF] {
          self.pc = self.pc + 2
        }
      } else if nn == 0xA1 {
        if !self.keys[self.v[x] & 0xF] {
          self.pc = self.pc + 2
        }
      } else {
        self.halt("bad EX__ opcode")
        return false
      }
    0x0F =>
      match nn {
        0x07 => self.v[x] = self.dt
        0x0A => {
          // wait for a key press: resolve on a later fetch
          let mut pressed = -1
          for k = 0; k < 16; k = k + 1 {
            if self.keys[k] {
              pressed = k
            }
          }
          if pressed < 0 {
            self.waiting = true
            self.pc = self.pc - 2 // re-execute FX0A next tick
          } else {
            self.v[x] = pressed
          }
        }
        0x15 => self.dt = self.v[x]
        0x18 => self.st = self.v[x]
        0x1E => self.i = (self.i + self.v[x]) & 0xFFFF
        0x29 => self.i = FONT_ADDR + (self.v[x] & 0xF) * 5
        0x33 => {
          let val = self.v[x]
          self.mem[self.i] = (val / 100).to_byte()
          self.mem[self.i + 1] = (val / 10 % 10).to_byte()
          self.mem[self.i + 2] = (val % 10).to_byte()
        }
        0x55 => {
          for k = 0; k <= x; k = k + 1 {
            self.mem[self.i + k] = self.v[k].to_byte()
          }
          if self.quirk_memory {
            self.i = self.i + x + 1
          }
        }
        0x65 => {
          for k = 0; k <= x; k = k + 1 {
            self.v[k] = self.mem[self.i + k].to_int()
          }
          if self.quirk_memory {
            self.i = self.i + x + 1
          }
        }
        _ => {
          self.halt("bad FX__ opcode")
          return false
        }
      }
    _ => {
      self.halt("unreachable")
      return false
    }
  }
  true
}

///|
fn Chip8::halt(self : Chip8, why : String) -> Unit {
  self.halted = true
  self.msg = why
}

///|
/// DXYN: draw an n-row sprite from memory[I..] at (Vx, Vy); VF = 1 when any
/// lit pixel was erased (XOR collision).
fn Chip8::draw_sprite(self : Chip8, x : Int, y : Int, rows : Int) -> Unit {
  let ox = self.v[x] % DISP_W
  let oy = self.v[y] % DISP_H
  let mut collision = 0
  for row = 0; row < rows; row = row + 1 {
    let bits = self.mem[self.i + row].to_int()
    let py = oy + row
    if py >= DISP_H {
      if self.quirk_clip {
        break
      }
    } else {
      for col = 0; col < 8; col = col + 1 {
        if ((bits >> (7 - col)) & 1) == 1 {
          let px = ox + col
          if px >= DISP_W {
            if self.quirk_clip {
              // skip this pixel but keep drawing the rest of the row on
              // original hardware the row simply stops at the edge
              break
            }
          } else {
            let idx = py * DISP_W + px
            if self.disp[idx] == 1 {
              collision = 1
            }
            self.disp[idx] = self.disp[idx] ^ 1
          }
        }
      }
    }
  }
  self.v[0xF] = collision
  self.drew = true
}

///|
/// Advance the VM one 60 Hz frame: run up to `ips_per_frame` instructions,
/// then tick the timers. Returns false when the VM halted.
pub fn Chip8::tick(self : Chip8, ips_per_frame : Int) -> Bool {
  let n = if ips_per_frame < 1 { 1 } else { ips_per_frame }
  for k = 0; k < n; k = k + 1 {
    if !self.step() {
      self.tick_timers()
      return false
    }
  }
  self.tick_timers()
  true
}

///|
/// Lit pixel at (x, y): 1 or 0.
pub fn Chip8::pixel(self : Chip8, x : Int, y : Int) -> Int {
  if x < 0 || x >= DISP_W || y < 0 || y >= DISP_H {
    return 0
  }
  self.disp[y * DISP_W + x].to_int()
}

///|
/// Number of lit pixels — test helper.
pub fn Chip8::lit_count(self : Chip8) -> Int {
  let mut s = 0
  for k = 0; k < DISP_W * DISP_H; k = k + 1 {
    s = s + self.disp[k].to_int()
  }
  s
}
