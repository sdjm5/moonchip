// CHIP-8 core unit tests. Programs are hand-assembled byte sequences; the
// ROM library games and the Timendus suite get their end-to-end pass in the
// kernel test (Node) and the browser.

///|
fn rom(bytes : Array[Int]) -> FixedArray[Byte] {
  let a : FixedArray[Byte] = FixedArray::make(bytes.length(), 0)
  for i = 0; i < bytes.length(); i = i + 1 {
    a[i] = bytes[i].to_byte()
  }
  a
}

///|
fn run(program : Array[Int], steps : Int) -> Chip8 {
  let c = Chip8::new()
  ignore(c.load_rom(rom(program)))
  for k = 0; k < steps; k = k + 1 {
    ignore(c.step())
  }
  c
}

///|
test "font is loaded at 0x50 and the zero glyph reads back" {
  let c = Chip8::new()
  // glyph for '0' is F0 90 90 90 F0
  assert_eq(c.mem[0x50].to_int(), 0xF0)
  assert_eq(c.mem[0x54].to_int(), 0xF0)
  assert_eq(c.mem[0x51].to_int(), 0x90)
}

///|
test "load/store, arithmetic and the carry flag" {
  // V0 = 250; V1 = 10; V0 += V1; VF
  let c = run([0x60, 250, 0x61, 10, 0x80, 0x14], 3)
  assert_eq(c.v[0], 4) // (250 + 10) & 0xFF
  assert_eq(c.v[0xF], 1)
  // 5 - 8 wraps and clears VF
  let c2 = run([0x60, 5, 0x61, 8, 0x80, 0x15], 3)
  assert_eq(c2.v[0], 253)
  assert_eq(c2.v[0xF], 0)
  // 8XY7: V0 = V1 - V0 when V1 > V0
  let c3 = run([0x60, 3, 0x61, 9, 0x80, 0x17], 3)
  assert_eq(c3.v[0], 6)
  assert_eq(c3.v[0xF], 1)
  // 7XNN adds without touching VF
  let c4 = run([0x60, 250, 0x70, 10], 2)
  assert_eq(c4.v[0], 4)
  assert_eq(c4.v[0xF], 0)
}

///|
test "logic ops reset VF per quirk" {
  // VF=1, then V0=0xF0, V1=0x0F, XOR → 0xFF; quirk on clears VF
  let c1 = run([0x6F, 1, 0x60, 0xF0, 0x61, 0x0F, 0x80, 0x13], 4)
  assert_eq(c1.v[0], 0xFF)
  assert_eq(c1.v[0xF], 0)
  // quirk off: VF keeps its old value
  let c3 = Chip8::new()
  ignore(c3.load_rom(rom([0x6F, 1, 0x60, 0xF0, 0x61, 0x0F, 0x80, 0x13])))
  c3.quirk_vf_reset = false
  for k = 0; k < 4; k = k + 1 {
    ignore(c3.step())
  }
  assert_eq(c3.v[0], 0xFF)
  assert_eq(c3.v[0xF], 1)
}

///|
test "shift uses VY on original hardware, VX otherwise" {
  // V2 = 5; V3 = 170; V2 = V3 >> 1 (quirk on)
  let prog = [0x62, 5, 0x63, 170, 0x82, 0x36]
  let c1 = run(prog, 3)
  assert_eq(c1.v[2], 85)
  assert_eq(c1.v[0xF], 0)
  let c2 = Chip8::new()
  ignore(c2.load_rom(rom(prog)))
  c2.quirk_shift = false
  for k = 0; k < 3; k = k + 1 {
    ignore(c2.step())
  }
  assert_eq(c2.v[2], 2) // V2 (5) >> 1
  assert_eq(c2.v[0xF], 1) // lost bit of 5
}

///|
test "shift left sets VF to the bit shifted out" {
  // quirk_shift is on: V2 = (V3 << 1) & 0xFF, VF = bit 7 of V3
  let c1 = run([0x62, 5, 0x63, 0x81, 0x82, 0x3E], 3)
  assert_eq(c1.v[2], 0x02)
  assert_eq(c1.v[0xF], 1)
}

///|
test "jumps, calls and returns" {
  // 0x200: 2 2 0A (call 0x20A); 0x204: 60 07 (V0=7); ...; 0x20A: 60 09 (V0=9); 00EE (ret)
  let c = run(
    [
      0x22, 0x0A, 0x60, 0x07, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x60, 0x09, 0x00,
      0xEE,
    ],
    3,
  )
  assert_eq(c.v[0], 9) // called routine ran
  // one more step: RET returns to 0x204
  ignore(c.step())
  assert_eq(c.pc, 0x204)
  // 1NNN jump
  let c2 = run([0x12, 0x08, 0x60, 1, 0x60, 1, 0x60, 1, 0x60, 42], 1)
  assert_eq(c2.pc, 0x208)
  for k = 0; k < 3; k = k + 1 {
    ignore(c2.step())
  }
  assert_eq(c2.v[0], 42)
  // 3XNN skip when equal (the skip consumes the extra step)
  let c3 = run([0x60, 5, 0x30, 5, 0x60, 1, 0x60, 2], 3)
  assert_eq(c3.v[0], 2) // skipped the "V0=1"
  // BNNN: jump to NNN + V0
  let c4 = run([0x60, 3, 0xB2, 0x06], 2)
  assert_eq(c4.pc, 0x209)
}

///|
test "BCD encoding" {
  // V0 = 237; I = 0x400; FX33
  let c = run([0x60, 237, 0xA4, 0x00, 0xF0, 0x33], 3)
  assert_eq(c.mem[0x400].to_int(), 2)
  assert_eq(c.mem[0x401].to_int(), 3)
  assert_eq(c.mem[0x402].to_int(), 7)
}

///|
test "FX55 stores registers; I increment per quirk" {
  // F155: x = 1 → stores V0 and V1
  let prog : Array[Int] = [0x60, 11, 0x61, 22, 0xA4, 0x00, 0xF1, 0x55]
  let c1 = run(prog, 4)
  assert_eq(c1.mem[0x400].to_int(), 11)
  assert_eq(c1.mem[0x401].to_int(), 22)
  assert_eq(c1.i, 0x400) // quirk_memory off by default
  let c2 = Chip8::new()
  ignore(c2.load_rom(rom(prog)))
  c2.quirk_memory = true
  for k = 0; k < 4; k = k + 1 {
    ignore(c2.step())
  }
  assert_eq(c2.i, 0x402) // original hardware increments I
}

///|
test "sprite draw, XOR erase and collision flag" {
  // sprite bytes at 0x400; the program draws twice by looping back to D012
  let prog2 : Array[Int] = [
    0xA4, 0x00, 0x60, 5, 0x61, 5, 0xD0, 0x12, // draw 2 rows at (V0, V1)
     0x12, 0x06, // jump back to the draw → XOR erases
  ]
  let c3 = Chip8::new()
  ignore(c3.load_rom(rom(prog2)))
  c3.mem[0x400] = (0xC0).to_byte()
  c3.mem[0x401] = (0xC0).to_byte()
  for k = 0; k < 4; k = k + 1 {
    ignore(c3.step())
  }
  assert_eq(c3.lit_count(), 4)
  assert_eq(c3.v[0xF], 0)
  for k = 0; k < 2; k = k + 1 {
    ignore(c3.step())
  }
  assert_eq(c3.lit_count(), 0) // XOR erased
  assert_eq(c3.v[0xF], 1) // collision detected
}

///|
test "sprites clip at the display edge per quirk" {
  // 8-wide sprite at x=62 → only 2 columns fit
  let prog : Array[Int] = [0xA4, 0x00, 0x60, 62, 0x61, 5, 0xD0, 0x11]
  let c = Chip8::new()
  ignore(c.load_rom(rom(prog)))
  c.mem[0x400] = (0xFF).to_byte()
  for k = 0; k < 4; k = k + 1 {
    ignore(c.step())
  }
  assert_eq(c.lit_count(), 2)
  assert_eq(c.pixel(62, 5), 1)
  assert_eq(c.pixel(63, 5), 1)
}

///|
test "FX29 points I at the digit font" {
  let c = run([0x60, 0x0C, 0xF0, 0x29], 2)
  assert_eq(c.i, 0x50 + 12 * 5)
}

///|
test "timers tick down at 60 Hz" {
  let c = run([0x60, 30, 0xF0, 0x15, 0xF0, 0x07], 2)
  assert_eq(c.dt, 30)
  for k = 0; k < 5; k = k + 1 {
    ignore(c.tick(1))
  }
  assert_eq(c.dt, 25)
  assert_eq(c.v[0], 30) // FX07 read happened before the ticks
}

///|
test "FX0A waits for a key press" {
  let c = Chip8::new()
  ignore(c.load_rom(rom([0xF0, 0x0A, 0x60, 1])))
  ignore(c.step())
  assert_true(c.waiting) // halted at FX0A
  ignore(c.step())
  assert_eq(c.v[0], 0) // still waiting, nothing stored
  c.key_down(5)
  ignore(c.step())
  assert_eq(c.v[0], 5) // key resolved
  assert_true(!c.waiting)
}

///|
test "CXNN is deterministic under a fixed seed" {
  let c1 = Chip8::new()
  ignore(c1.load_rom(rom([0xC0, 0xFF])))
  c1.seed(12345)
  ignore(c1.step())
  let c2 = Chip8::new()
  ignore(c2.load_rom(rom([0xC0, 0xFF])))
  c2.seed(12345)
  ignore(c2.step())
  assert_eq(c1.v[0], c2.v[0])
}

///|
test "keypad skips: EX9E and EXA1" {
  // V0 = 5; EX9E skips when key 5 down
  let c = Chip8::new()
  ignore(c.load_rom(rom([0x60, 5, 0xE0, 0x9E, 0x60, 1, 0x60, 2])))
  c.key_down(5)
  for k = 0; k < 3; k = k + 1 {
    ignore(c.step())
  }
  assert_eq(c.v[0], 2) // skipped the V0=1
  // EXA1 skips when key NOT down
  let c2 = Chip8::new()
  ignore(c2.load_rom(rom([0x60, 5, 0xE0, 0xA1, 0x60, 1, 0x60, 2])))
  c2.key_down(5)
  for k = 0; k < 3; k = k + 1 {
    ignore(c2.step())
  }
  assert_eq(c2.v[0], 1) // did not skip
}

///|
test "stack overflow halts cleanly" {
  // infinite self-call: 2 2 00
  let c = run([0x22, 0x00], 30)
  assert_true(c.halted)
  assert_eq(c.msg, "stack overflow")
}
