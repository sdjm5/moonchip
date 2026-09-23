// Wasm boundary for the CHIP-8 VM.
//
// The host loads a ROM by writing its raw bytes into linear memory and
// calling `load_rom`; every frame it calls `tick(ips)` and reads the freshly
// rendered 64×32 display bitmap straight out of linear memory. Keypad and
// quirk switches are plain exported calls. State crosses only in bulk —
// one call and one typed-array read per frame, no per-pixel or per-register
// boundary traffic.

///|
extern "wasm" fn load8(addr : Int) -> Int =
  #|(func (param $addr i32) (result i32) (i32.load8_u (local.get $addr)))

///|
extern "wasm" fn store8(addr : Int, v : Int) -> Unit =
  #|(func (param $addr i32) (param $v i32) (i32.store8 (local.get $addr) (local.get $v)))

///|
extern "wasm" fn store_u32(addr : Int, v : Int) -> Unit =
  #|(func (param $addr i32) (param $v i32) (i32.store (local.get $addr) (local.get $v)))

///|
let vm : @ref.Ref[@lib.Chip8?] = @ref.Ref(None)

///|
/// Create the VM.
#export_name("moon_init")
pub fn vm_init() -> Unit {
  vm.val = Some(@lib.Chip8::new())
}

///|
/// Load `len` bytes of ROM from linear memory at `addr` into RAM at 0x200
/// and reset the machine. Returns the loaded length or -1 when it does not
/// fit.
#export_name("load_rom")
pub fn load_rom(addr : Int, len : Int) -> Int {
  match vm.val {
    Some(c) => {
      let rom : FixedArray[Byte] = FixedArray::make(len, 0)
      for k = 0; k < len; k = k + 1 {
        rom[k] = load8(addr + k).to_byte()
      }
      let loaded = c.load_rom(rom)
      if loaded >= 0 {
        c.reset()
        loaded
      } else {
        -1
      }
    }
    None => -1
  }
}

///|
#export_name("key_down")
pub fn key_down(k : Int) -> Unit {
  match vm.val {
    Some(c) => c.key_down(k)
    None => ()
  }
}

///|
#export_name("key_up")
pub fn key_up(k : Int) -> Unit {
  match vm.val {
    Some(c) => c.key_up(k)
    None => ()
  }
}

///|
/// Run one 60 Hz frame: up to `ips` instructions, then timer tick.
/// Returns 1 while the VM is running, 0 when halted.
#export_name("tick")
pub fn tick(ips : Int) -> Int {
  match vm.val {
    Some(c) => if c.tick(ips) { 1 } else { 0 }
    None => 0
  }
}

///|
/// Write the 64×32 display bitmap (2048 bytes of 0/1) to `addr`.
#export_name("render_display")
pub fn render_display(addr : Int) -> Unit {
  match vm.val {
    Some(c) =>
      for k = 0; k < 2048; k = k + 1 {
        store8(addr + k, c.disp[k].to_int())
      }
    None => ()
  }
}

///|
/// Write debug state as 21 u32 words: pc, i, sp, dt, st, v0..vf.
#export_name("state_out")
pub fn state_out(addr : Int) -> Unit {
  match vm.val {
    Some(c) => {
      store_u32(addr, c.pc)
      store_u32(addr + 4, c.i)
      store_u32(addr + 8, c.sp)
      store_u32(addr + 12, c.dt)
      store_u32(addr + 16, c.st)
      for k = 0; k < 16; k = k + 1 {
        store_u32(addr + 20 + k * 4, c.v[k])
      }
    }
    None => ()
  }
}

///|
/// Toggle a quirk: 0 VF-reset, 1 memory I-increment, 2 shift-uses-VY,
/// 3 sprite clipping.
#export_name("set_quirk")
pub fn set_quirk(id : Int, on : Int) -> Unit {
  match vm.val {
    Some(c) => {
      let flag = on != 0
      match id {
        0 => c.quirk_vf_reset = flag
        1 => c.quirk_memory = flag
        2 => c.quirk_shift = flag
        3 => c.quirk_clip = flag
        _ => ()
      }
    }
    None => ()
  }
}

///|
/// Seed the VM's PRNG (deterministic replay of CXNN).
#export_name("seed")
pub fn seed(s : Int) -> Unit {
  match vm.val {
    Some(c) => c.seed(s)
    None => ()
  }
}

///|
#export_name("reset")
pub fn reset() -> Unit {
  match vm.val {
    Some(c) => c.reset()
    None => ()
  }
}

///|
/// 1 while the sound timer counts down.
#export_name("sound_active")
pub fn sound_active() -> Int {
  match vm.val {
    Some(c) => if c.st > 0 { 1 } else { 0 }
    None => 0
  }
}

///|
/// 0 while the VM runs; halted VMs stop executing.
#export_name("halted")
pub fn halted() -> Int {
  match vm.val {
    Some(c) => if c.halted { 1 } else { 0 }
    None => 1
  }
}

///|
/// Total instructions executed since boot (debug HUD).
#export_name("opcount")
pub fn opcount() -> Int {
  match vm.val {
    Some(c) => c.opcount
    None => 0
  }
}

///|
/// Read one byte of the VM's internal RAM (tests poke sprite data here).
#export_name("ram_read")
pub fn ram_read(addr : Int) -> Int {
  match vm.val {
    Some(c) =>
      if addr >= 0 && addr < @lib.MEM_SIZE {
        c.mem[addr].to_int()
      } else {
        0
      }
    None => 0
  }
}

///|
/// Write one byte of the VM's internal RAM.
#export_name("ram_write")
pub fn ram_write(addr : Int, v : Int) -> Unit {
  match vm.val {
    Some(c) =>
      if addr >= 0 && addr < @lib.MEM_SIZE {
        c.mem[addr] = v.to_byte()
      }
    None => ()
  }
}
