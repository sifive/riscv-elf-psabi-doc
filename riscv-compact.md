# RISC-V Compact Code Model

#### Evandro Menezes
#### evandro.menezes@sifive.com

## Introduction

Code models are based on the portion of the total address space that may be reached.  The native range of instructions usually determines the code models.  The range of instructions such as branches and loads may determine different code models to reach code and data in the address space.

When the code or data of a program is within the native range of instructions, it is deemed "small". When the code or data of a program is without the native range of instructions, it is deemed "large". Code models are sometimes defined as:

| Code models | Small code | Large code |
| --- | --- | --- |
| **Small data** | Small model | Medium model |
| **Large data** | Compact model | Large model |

## RISC-V Data Models

| Data models | Address space | Code addressing range | Data addressing range |
| --- | --- | --- | --- |
| **ILP32** | 4GiB | 4GiB | 4GiB |
| **LP64** | 16EiB | 2GiB | 4GiB |

For ILP32, the whole address space is within the native range for both code and data. Therefore, the small code model is sufficient.

For LP64, only 2GiB of the address space is within the native range for code and 4GiB for data. The existing small code models, `medlow` & `medany`, are not sufficient.

## RISC-V LP64 Code Models

In order to access more than 2GiB of code and 4GiB of data, the native instructions are not sufficient:
- More than 2GiB of code and 4GiB of data can only be reached indirectly via a 64 bit register.
- 64 bit constants are not natively supported by the RV64I instructions.
- Forming 64 bit constants using several instructions is not optimal.

Thus, supporting the whole address space of 16EiB of code adds prohibitive costs to call sites. Therefore, neither the medium nor the large code models are feasible.

However, the cost to support the address space of 16EiB of data may be acceptable. This compact code model is proposed below.

## RV64 Compact Model

Though this proposal for a compact code model includes the case when there is more than 4GiB of initialized data, it is not the case that is primarily addressed by the new specification.  Rather, accessing data anywhere in the whole address space is the primary case addressed by it.

Since the global pointer is the anchor to access global data, the gp register is thus required to be preserved across function calls.

If the global variable has local scope, it is allocated in or adjacent to the global data area. The limit for data of local scope is 2GiB. It is accessed relative to the global pointer.

If the global variable has global scope, it may be allocated anywhere in the address space. There is no limit for data of global scope. It is accessed indirectly through a GOT entry that contains its address, with a corresponding R_RISCV_64 relocation for the entry. When the program is loaded, the dynamic linker should process this relocation. In the absence of a loader, the linker records the symbol value in the GOT entry. Note that then the GOT is used for both non PIC and PIC objects.

These new relocation functions are added to the assembler:
- `%gprel_hi(<symbol>)`, `%gprel_lo(<symbol>)`: offset from the global pointer to the symbol.
- `%got_gprel_hi(<symbol>)`, `%got_gprel_lo(<symbol>)`: offset from the global pointer to the GOT entry for the symbol.
- `%gprel(<symbol>)`, `%gprel_add(<symbol>)`, `%got_gprel(<symbol>)`, `%got_gprel_add(<symbol>)`: note instruction for relaxation purposes.

These new relocation types are added:

| Relocation type | Calculation[^1] | Details |
| --- | --- | --- |
| `R_RISCV_GPREL_HI20` | S + A - GP | `%gprel_hi(<symbol>)` |
| `R_RISCV_GPREL_LO12_I`[^2] | S + A - GP | `%gprel_lo(<symbol>)` |
| `R_RISCV_GPREL_LO12_S`[^2] | S + A - GP | `%gprel_lo(<symbol>)` |
| `R_RISCV_GPREL_ADD` |  | `%gprel_add(<symbol>)` |
| `R_RISCV_GPREL_LOAD` |  | `%gprel(<symbol>)` |
| `R_RISCV_GPREL_STORE` |  | `%gprel(<symbol>)` |
| `R_RISCV_GOT_GPREL_HI20` | G + A - GP | `%got_gprel_hi(<symbol>)` |
| `R_RISCV_GOT_GPREL_LO12_I` | G + A - GP | `%got_gprel_lo(<symbol>)` |
| `R_RISCV_GOT_GPREL_ADD` |  | `%got_gprel_add(<symbol>)` |
| `R_RISCV_GOT_GPREL_LOAD` |  | `%got_gprel(<symbol>)` |
| `R_RISCV_GOT_GPREL_STORE` |  | `%got_gprel(<symbol>)` |
| `R_RISCV_64_PCREL` | S + A - P |  |

[^1]: Legend for the relocation calculations:
  A: the addend used to compute the value of the relocatable field.
  G: the offset into the GOT where the value of the symbol will reside.
  GP: represents the address of the global data area.
  P: the place (section offset or address) of the relocation.
  S: the value of the symbol.

[^2]: The relocation types `R_RISCV_GPREL_LO12_I` and `R_RISCV_GPREL_LO12_S` are relaxed into `R_RISCV_GPREL_I` and `R_RISCV_GPREL_S` respectively.

This new ELF header flag is added:
* `EF_RISCV_COMPACT` (`e_flags & 0x20`): This bit is set when the binary targets the compact code model.

## Compact Model Coding Examples

### Function Prolog

Functions in executable objects expect that the `gp` register was initialized to the global pointer at program start up.

Functions in shared objects that refer to the global pointer must setup the `gp` register in its prolog, for example:

```assembly
  auipc	gp, %pcrel_hi(__global_pointer__)
  addi	gp, gp, %pcrel_lo(__global_pointer__)
  ld	t0, 0(gp)
  add	gp, gp, t0
  ...
  .section .text.__global_pointer__, "aMG", @progbits, 8, __global_pointer__, comdat
  .align 3
  .hidden __global_pointer__
  .type	__global_pointer__, object
__global_pointer__:
  .quad	__global_pointer$ -.
```

The expression `__global_pointer$ - .` results in the relocation type `R_RISCV_64_PCREL`. This relocation is position independent, provided that the information available to the linker matches the run time environment, therefore it can be used in both executable and shared objects.

Note that the code example above places the literal for the global data area in a comdat section that is shared by all references to this literal in the object.

### Data Objects

The code examples below assume that the `gp` register points to the global data area.

| Source | Assembly | Relocations |
| -- | -- | -- |
| `extern int src;` | `.extern src`		| `R_RISCV_64` |
| `extern int dst;` | `.extern dst`		| `R_RISCV_64` |
| `extern void *ptr;` | `.extern ptr`		| `R_RISCV_64` |
| `static int lsrc;` | `.comm .Llsrc, 4`		|  |
| `static int ldst;` | `.comm .Lldst, 4`		|  |
| `static void foo(void);` | `.local foo`		|  |
|  | `.text` |  |
| `dst = src;` | `lui	t0, %got_gprel_hi(src)`	| `R_RISCV_GOT_GPREL_HI20` |
|  | `add	t0, t0, gp, %got_gprel(src)`	| `R_RISCV_GOT_GPREL_ADD` |
|  | `ld		t0, %got_gprel_lo(src)(t0)`	| `R_RISCV_GOT_GPREL_LO12_I` |
|  | `lw		t2, 0(t0), %got_gprel(src)`	| `R_RISCV_GOT_GPREL_LOAD` |
|  | `lui	t1, %got_gprel_hi(dst)`		| `R_RISCV_GOT_GPREL_HI20` |
|  | `add	t1, t1, gp, %got_gprel(dst)`	| `R_RISCV_GOT_GPREL_ADD` |
|  | `ld		t1, %got_gprel_lo(dst)(t1)`	| `R_RISCV_GOT_GPREL_LO12_I` |
|  | `sw		t2, 0(t1), %got_gprel(dst)`	| `R_RISCV_GOT_GPREL_STORE` |
| `ptr = &src;` | `lui	t0, %got_gprel_hi(src)`	| `R_RISCV_GOT_GPREL_HI20` |
|  | `add	t0, t0, gp, %got_gprel(src)`	| `R_RISCV_GOT_GPREL_ADD` |
|  | `ld		t0, %got_gprel_lo(src)(t0)`	| `R_RISCV_GOT_GPREL_LO12_I` |
|  | `lui	t1, %got_gprel_hi(ptr)`		| `R_RISCV_GOT_GPREL_HI20` |
|  | `add	t1, t1, gp, %got_gprel(ptr)`	| `R_RISCV_GOT_GPREL_ADD` |
|  | `ld		t1, %got_gprel_lo(ptr)(t1)`	| `R_RISCV_GOT_GPREL_LO12_I` |
|  | `sd		t0, 0(t1), %got_gprel(ptr)`	| `R_RISCV_GOT_GPREL_STORE` |
| `ldst = &lsrc;` | `lui	t0, %gprel_hi(.Llsrc)`	| `R_RISCV_GPREL_HI20` |
|  | `add	t0, t0, gp, %gprel(.Llsrc)`	| `R_RISCV_GPREL_ADD` |
|  | `addi	t0, t0, %gprel_lo(.Llsrc)`		| `R_RISCV_GPREL_LO12_I` |
|  | `lui	t1, %gprel_hi(.Lldst)`		| `R_RISCV_GPREL_HI20` |
|  | `add	t1, t1, gp, %gprel(.Lldst)`	| `R_RISCV_GPREL_ADD` |
|  | `sd		t0, %gprel_lo(.Lldst)(t1)`		| `R_RISCV_GPREL_LO12_S` |
| `ptr = foo;` | `la	t0, foo`			| `R_RISCV_PCREL_HI20` |
|  |  						| `R_RISCV_PCREL_LO12_I` |
|  | `lui	t1, %got_gprel_hi(ptr)`		| `R_RISCV_GOT_GPREL_HI20` |
|  | `add	t1, t1, gp, %got_gprel(ptr)`	| `R_RISCV_GOT_GPREL_ADD` |
|  | `ld		t1, %got_gprel_lo(ptr)(t1)`	| `R_RISCV_GOT_GPREL_LO12_I` |
|  | `sd		t0, 0(t1), %got_gprel(ptr)`	| `R_RISCV_GOT_GPREL_STORE` |

## Relaxation

The cost of the compact code model can be quite significant, so it is important to minimize this cost when the conditions allow for it. This can be done at link time through the addition of special relocation types to allow it. Additionally, additional assembly macros simplify adding such special relocations.

### Address Literals

This macro is used to produce the literal for a local symbol:

```assembly
lla	<rd>, %gprel(<symbol>)
```

Which expands to:

```assembly
lui	<rd>, %gprel_hi(<symbol>)			// R_RISCV_GPREL_HI20 (symbol)
add	<rd>, <rd>, gp, %gprel(<symbol>)		// R_RISCV_GPREL_ADD (symbol)
addi	<rd>, <rd>, %gprel_lo(<symbol>)		// R_RISCV_GPREL_LO12_I (symbol)
```

If the literal for the symbol is allocated within the global data area, then this sequence may be relaxed to:

```assembly
addi	<rd>, gp, %gprel_lo(<symbol>)		// R_RISCV_GPREL_I (symbol)
```

For a global symbol, this macro is used to produce its literal:

```assembly
la	<rd>, %got_gprel(<symbol>)
```

Which expands to:

```assembly
lui	<rd>, %got_gprel_hi(<symbol>)		// R_RISCV_GOT_GPREL_HI20 (symbol)
add	<rd>, <rd>, gp, %got_gprel(<symbol>)	// R_RISCV_GOT_GPREL_ADD (symbol)
ld	<rd>, %got_gprel_lo(<symbol>)(<rd>)		// R_RISCV_GOT_GPREL_LO12_I (symbol)
```

If the GOT entry for the literal is allocated in the vicinity of the global data area, then this sequence may be relaxed to:

```assembly
ld	<rd>, %got_gprel_lo(<symbol>)(gp)		// R_RISCV_GOT_GPREL_LO12_I (symbol)
```

If the global symbol is allocated in the executable object, then this macro is equivalent to:

```assembly
lla	<rd>, %gprel(<symbol>)
```

### Loads and Stores

For loading from or storing to a local symbol, these macros are used:

```assembly
l{b|h|w|d} <rd>, %gprel(<symbol>)
s{b|h|w|d} <rd>, %gprel(<symbol>), <rt>
fl{h|w|d|q} <rd>, %gprel(<symbol>), <rt>
fs{h|w|d|q} <rd>, %gprel(<symbol>), <rt>
```

Which expand to:

```assembly
lui	<rd>, %gprel_hi(<symbol>)			// R_RISCV_GPREL_HI20 (symbol)
add	<rd>, <rd>, gp, %gprel(<symbol>)		// R_RISCV_GPREL_ADD (symbol)
l{b|h|w|d} <rd>, %gprel_lo(<symbol>)(<rd>)		// R_RISCV_GPREL_LO12_I (symbol)
```

And:

```assembly
lui	<rt>, %gprel_hi(<symbol>)			// R_RISCV_GPREL_HI20 (symbol)
add	<rt>, <rt>, gp, %gprel(<symbol>)		// R_RISCV_GPREL_ADD (symbol)
s{b|h|w|d} <rd>, %gprel_lo(<symbol>)(<rt>)		// R_RISCV_GPREL_LO12_S (symbol)
```

And:

```assembly
lui	<rt>, %gprel_hi(<symbol>)			// R_RISCV_GPREL_HI20 (symbol)
add	<rt>, <rt>, gp, %gprel(<symbol>)		// R_RISCV_GPREL_ADD (symbol)
fl{h|w|d|q} <rd>, %gprel_lo(<symbol>)(<rt>)		// R_RISCV_GPREL_LO12_I (symbol)
```

And:

```assembly
lui	<rt>, %gprel_hi(<symbol>)			// R_RISCV_GPREL_HI20 (symbol)
add	<rt>, <rt>, gp, %gprel(<symbol>)		// R_RISCV_GPREL_ADD (symbol)
fs{h|w|d|q} <rd>, %gprel_lo(<symbol>)(<rt>)		// R_RISCV_GPREL_LO12_S (symbol)
```

If the symbol is allocated within the global data area, then these sequences may be relaxed to:

```assembly
l{b|h|w|d}	<rd>, %gprel_lo(<symbol>)(gp)	// R_RISCV_GPREL_I (symbol)
```

And:

```assembly
s{b|h|w|d}	<rd>, %gprel_lo(<symbol>)(gp)	// R_RISCV_GPREL_S (symbol)
```

And:

```assembly
fl{h|w|d|q}	<rd>, %gprel_lo(<symbol>)(gp)	// R_RISCV_GPREL_I (symbol)
```

And:

```assembly
fs{h|w|d|q}	<rd>, %gprel_lo(<symbol>)(gp)	// R_RISCV_GPREL_S (symbol)
```

For loading from or storing to a global symbol, these macros are used:

```assembly
l{b|h|w|d} <rd>, <offset>(<rt>), %got_gprel(<symbol>)
s{b|h|w|d} <rd>, <offset>(<rt>), %got_gprel(<symbol>)
fl{h|w|d|q} <rd>, <offset>(<rt>), %got_gprel(<symbol>)
fs{h|w|d|q} <rd>, <offset>(<rt>), %got_gprel(<symbol>)
```

Which expand to:

```assembly
l{b|h|w|d} <rd>, <offset>(<rt>)			// R_RISCV_GOT_GPREL_LOAD (symbol)
s{b|h|w|d} <rd>, <offset>(<rt>)			// R_RISCV_GOT_GPREL_STORE (symbol)
fl{h|w|d|q} <rd>, <offset>(<rt>)			// R_RISCV_GOT_GPREL_LOAD (symbol)
fs{h|w|d|q} <rd>, <offset>(<rt>)			// R_RISCV_GOT_GPREL_STORE (symbol)
```

If the global symbol is allocated and referenced within the global data area of the executable object, then these macros are equivalent to:

```assembly
l{b|h|w|d} <rd>, %gprel_lo(<symbol> + <offset>)(gp)	// R_RISCV_GPREL_LO12_I (symbol)
```

And:

```assembly
s{b|h|w|d} <rd>, %gprel_lo(<symbol> + <offset>)(gp)	// R_RISCV_GPREL_LO12_S (symbol)
```

And:

```assembly
fl{h|w|d|q} <rd>, %gprel_lo(<symbol> + <offset>)(gp)	// R_RISCV_GPREL_LO12_I (symbol)
```

And:

```assembly
fs{h|w|d|q} <rd>, %gprel_lo(<symbol> + <offset>)(gp)	// R_RISCV_GPREL_LO12_S (symbol)
```

## Appendix

The table below demonstrates the results of relaxation when the global is allocated and referenced in the executable object:


| Source | Assembly | Relocations | Relaxed | Relocations |
| --     | --       | --          | --      | --          |
| `extern int src;` | `.extern src` |  |  |  |
| `extern int dst;` | `.extern dst` |  |  |  |
| `extern void *ptr;` | `.extern ptr` |  |  |  |
| `static void foo(void);` | `.local foo` |  |  |  |
|  | `.text` |  |  |  |
| `dst = src;`	| `lui	t0, %got_gprel_hi(src)`	| `R_RISCV_GOT_GPREL_HI20`		| `lui	t0, %gprel_hi(src)`	| `R_RISCV_GPREL_HI20` |
|  | `add	t0, t0, gp, %got_gprel(src)`	| `R_RISCV_GOT_GPREL_ADD`		| `add	t0, t0, gp` |
|  | `ld		t0, %got_gprel_lo(src)(t0)`	| `R_RISCV_GOT_GPREL_LO12_I`	| `addi	t0, t0, %gprel_lo(src)`	| `R_RISCV_GPREL_I` |
|  | `lw		t2, 0(t0), %got_gprel(src)`	| `R_RISCV_GOT_GPREL_LOAD`		| `lw	t2, 0(t0)` |
|  | `lui	t1, %got_gprel_hi(dst)`		| `R_RISCV_GOT_GPREL_HI20`		| `lui	t1, %gprel_hi(dst)`	| `R_RISCV_GPREL_HI20` |
|  | `add	t1, t1, gp, %got_gprel(dst)`	| `R_RISCV_GOT_GPREL_ADD`		| `add	t1, t1, gp` |
|  | `ld		t1, %got_gprel_lo(dst)(t1)`	| `R_RISCV_GOT_GPREL_LO12_I`	| `addi	t1, t1, %gprel_lo(dst)`	| `R_RISCV_GPREL_I` |
|  | `sw		t2, 0(t1), %got_gprel(dst)`	| `R_RISCV_GOT_GPREL_STORE`	| `sw	t2, 0(t1)` |
| `ptr = &src;`	| `lui	t0, %got_gprel_hi(src)`	| `R_RISCV_GOT_GPREL_HI20`		| `lui	t0, %gprel_hi(src)`	| `R_RISCV_GPREL_HI20` |
|  | `add	t0, t0, gp, %got_gprel(src)`	| `R_RISCV_GOT_GPREL_ADD`		| `add	t0, t0, gp` |
|  | `ld		t0, %got_gprel_lo(src)(t0)`	| `R_RISCV_GOT_GPREL_LO12_I`	| `addi	t0, t0, %gprel_lo(src)`	| `R_RISCV_GPREL_I` |
|  | `lui	t1, %got_gprel_hi(ptr)`		| `R_RISCV_GOT_GPREL_HI20`		| `lui	t1, %gprel_hi(ptr)`	| `R_RISCV_GPREL_HI20` |
|  | `add	t1, t1, gp, %got_gprel(ptr)` 	| `R_RISCV_GOT_GPREL_ADD`		| `add	t1, t1, gp` |
|  | `ld		t1, %got_gprel_lo(ptr)(t1)`	| `R_RISCV_GOT_GPREL_LO12_I`	| `addi	t1, t1, %gprel_lo(ptr)`	| `R_RISCV_GPREL_I` |
|  | `sd		t0, 0(t1), %got_gprel(ptr)`	| `R_RISCV_GOT_GPREL_STORE`	| `sd	t0, 0(t1)` |
| `ptr = foo;`	| `la	t0, foo`			| `R_RISCV_PCREL_HI20`		| `la	t0, foo` 		| `R_RISCV_PCREL_HI20` |
|  |						| `R_RISCV_PCREL_LO12_I`		|				| `R_RISCV_PCREL_LO12_I` |
|  | `lui	t1, %got_gprel_hi(ptr)`		| `R_RISCV_GOT_GPREL_HI20`		| `lui	t1, %gprel_hi(ptr)`	| `R_RISCV_GPREL_HI20` |
|  | `add	t1, t1, gp, %got_gprel(ptr)`	| `R_RISCV_GOT_GPREL_ADD`		| `add	t1, t1, gp` |
|  | `ld		t1, %got_gprel_lo(ptr)(t1)`	| `R_RISCV_GOT_GPREL_LO12_I`	| `addi	t1, t1, %gprel_lo(ptr)`	| `R_RISCV_PCREL_LO12_I` |
|  | `sd		t0, 0(t1), %got_gprel(ptr)`	| `R_RISCV_GOT_GPREL_STORE`	| `sd	t0, 0(t1)` |

The table below demonstrates the results of relaxation when the GOT entry for the global is in the vicinity of the global data area:

| Source | Assembly | Relocations | Relaxed | Relocations |
| --     | --       | --          | --      | --          |
| `extern int src;` | `.extern src` |  |  |  |
| `extern int dst;` | `.extern dst` |  |  |  |
| `extern void *ptr;` | `.extern ptr` |  |  |  |
| `static void foo(void);` | `.local foo` |  |  |  |
|  | `.text` |  |  |  |
| `dst = src;`	| `lui	t0, %got_gprel_hi(src)`	| `R_RISCV_GOT_GPREL_HI20`		|  |
|  | `add	t0, t0, gp, %got_gprel(src)`	| `R_RISCV_GOT_GPREL_ADD`		|  |
|  | `ld		t0, %got_gprel_lo(src)(t0)`	| `R_RISCV_GOT_GPREL_LO12_I`	| `ld t0, %got_gprel_lo(src)(gp)`	| `R_RISCV_GOT_GPREL_LO12_I` |
|  | `lw		t2, 0(t0), %got_gprel(src)`	| `R_RISCV_GOT_GPREL_LOAD`		| `lw t2, 0(t0)` |
|  | `lui	t1, %got_gprel_hi(dst)`		| `R_RISCV_GOT_GPREL_HI20`		|  |
|  | `add	t1, t1, gp, %got_gprel(dst)`	| `R_RISCV_GOT_GPREL_ADD`		|  |
|  | `ld		t1, %got_gprel_lo(dst)(t1)`	| `R_RISCV_GOT_GPREL_LO12_I`	| `ld t1, %got_gprel_lo(dst)(gp)`	| `R_RISCV_GOT_GPREL_LO12_I` |
|  | `sw		t2, 0(t1), %got_gprel(dst)`	| `R_RISCV_GOT_GPREL_STORE`	| `sw t2, 0(t1)` |
| `ptr = &src;`	 | `lui	t0, %got_gprel_hi(src)`	| `R_RISCV_GOT_GPREL_HI20`		|  |
|  | `add 	t0, t0, gp, %got_gprel(src)`	| `R_RISCV_GOT_GPREL_ADD`		|  |
|  | `ld		 t0, %got_gprel_lo(src)(t0)`	| `R_RISCV_GOT_GPREL_LO12_I`	| `ld t0, %got_gprel_lo(src)(gp)`	| `R_RISCV_GOT_GPREL_LO12_I` |
|  | `lui 	t1, %got_gprel_hi(ptr)`		| `R_RISCV_GOT_GPREL_HI20`		|  |
|  | `add 	t1, t1, gp, %got_gprel(ptr)`	| `R_RISCV_GOT_GPREL_ADD`		|  |
|  | `ld 	t1, %got_gprel_lo(ptr)(t1)`	| `R_RISCV_GOT_GPREL_LO12_I`	|`ld t1, %got_gprel_lo(ptr)(gp)`	| `R_RISCV_GOT_GPREL_LO12_I` |
|  | `sd 	t0, 0(t1), %got_gprel(ptr)`	| `R_RISCV_GOT_GPREL_STORE`	|`sd t0, 0(t1)` |
| `ptr = foo;`	| `la	t0, foo`			| `R_RISCV_PCREL_HI20`		| `la t0, foo`			| `R_RISCV_PCREL_HI20` |
|  |						| `R_RISCV_PCREL_LO12_I`		|				| `R_RISCV_PCREL_LO12_I` |
|  | `lui	t1, %got_gprel_hi(ptr)`		| `R_RISCV_GOT_GPREL_HI20`		|  |
|  | `add	t1, t1, gp, %got_gprel(ptr)`	| `R_RISCV_GOT_GPREL_ADD`		|  |
|  | `ld		t1, %got_gprel_lo(ptr)(t1)`	| `R_RISCV_GOT_GPREL_LO12`		| `ld t1, %got_gprel_lo(ptr)(gp)`	| `R_RISCV_GOT_GPREL_LO12_I` |
|  | `sd		t0, 0(t1), %got_gprel(ptr)`	| `R_RISCV_GOT_GPREL_STORE`	| `sd t0, 0(t1)` |

The table below demonstrates the results of relaxation when the global is allocated and referenced in the global data area of the executable object:

| Source | Assembly | Relocations | Relaxed | Relocations |
| --     | --       | --          | --      | --          |
| `extern int src;` | `.extern src` |  |  |  |
| `extern int dst;` | `.extern dst` |  |  |  |
| `extern void *ptr;` | `.extern ptr` |  |  |  |
| `static void foo(void);` | `.local foo` |  |  |  |
|  | `.text` |  |  |  |
| `dst = src;` | `lui	t0, %got_gprel_hi(src)`	| `R_RISCV_GOT_GPREL_HI20`		|  |
|  | `add	t0, t0, gp, %got_gprel(src)`	| `R_RISCV_GOT_GPREL_ADD`		|  |
|  | `ld		t0, %got_gprel_lo(src)(t0)`	| `R_RISCV_GOT_GPREL_LO12`		| `addi	t0, gp, %gprel_lo(src)`	| `R_RISCV_GPREL_I` |
|  | `lw		t2, 0(t0), %got_gprel(src)`	| `R_RISCV_GOT_GPREL_LOAD`		| `lw	t2, %gprel_lo(src)(gp)`	| `R_RISCV_GPREL_I` |
|  | `lui	t1, %got_gprel_hi(dst)`		| `R_RISCV_GOT_GPREL_HI20`		|  |
|  | `add	t1, t1, gp, %got_gprel(dst)`	| `R_RISCV_GOT_GPREL_ADD`		|  |
|  | `ld		t1, %got_gprel_lo(dst)(t1)`	| `R_RISCV_GOT_GPREL_LO12`		| `addi	t1, gp, %gprel_lo(dst)`	| `R_RISCV_GPREL_I` |
|  | `sw		t2, 0(t1), %got_gprel(dst)`	| `R_RISCV_GOT_GPREL_STOR`		| `sw	t2, %gprel_lo(dst)(gp)`	| `R_RISCV_GPREL_S` |
| `ptr = &src;` | `lui	t0, %got_gprel_hi(src)`	| `R_RISCV_GOT_GPREL_HI20`		|  |
|  | `add	t0, t0, gp, %got_gprel(src)`	| `R_RISCV_GOT_GPREL_ADD`		|  |
|  | `ld		t0, %got_gprel_lo(src)(t0)`	| `R_RISCV_GOT_GPREL_LO12_I`	| `addi	t0, gp, %gprel_lo(src)`	| `R_RISCV_GPREL_I` |
|  | `lui	t1, %got_gprel_hi(ptr)`		| `R_RISCV_GOT_GPREL_HI20`		|  |
|  | `add	t1, t1, gp, %got_gprel(ptr)`	| `R_RISCV_GOT_GPREL_ADD`		|  |
|  | `ld		t1, %got_gprel_lo(ptr)(t1)`	| `R_RISCV_GOT_GPREL_LO12_I`	| `addi	t1, gp, %gprel_lo(ptr)`	| `R_RISCV_GPREL_I` |
|  | `sd		t0, 0(t1), %got_gprel(ptr)`	| `R_RISCV_GOT_GPREL_STORE`	| `sd	t0, %gprel_lo(ptr)(gp)`	| `R_RISCV_GPREL_S` |
| `ldst = &lsrc;` | `lui	t0, %gprel_hi(.Llsrc)`	| `R_RISCV_GPREL_HI20`		|  |
|  | `add	t0, t0, gp, %gprel(.Llsrc)`	| `R_RISCV_GPREL_ADD`		|  |
|  | `addi	t0, t0, %gprel_lo(.Llsrc)`		| `R_RISCV_GPREL_LO12_I`		| `addi	t0, gp, %gprel_lo(.Llsrc)`	| `R_RISCV_GPREL_I` |
|  | `lui	t1, %gprel_hi(.Lldst)`		|				|  |
|  | `add	t1, t1, gp, %gprel(.Lldst)`	| `R_RISCV_GPREL_ADD`		| `addi	t1, gp, %gprel_lo(.Lldst)`	| `R_RISCV_GPREL_I` |
|  | `sd		t0, %gprel_lo(.Lldst)(t1)`		|				| `sd	t0, %gprel_lo(.Lldst)(gp)`	| `R_RISCV_GPREL_S` |
| `ptr = foo;` | `la	t0, foo`			| `R_RISCV_PCREL_HI20`		| `la	t0, foo`			| `R_RISCV_PCREL_HI20` |
|  |						| `R_RISCV_PCREL_LO12_I`		|				| `R_RISCV_PCREL_LO12_I` |
|  | `lui	t1, %got_gprel_hi(ptr)`		| `R_RISCV_GOT_GPREL_HI20`		|  |
|  | `add	t1, t1, gp, %got_gprel(ptr)`	| `R_RISCV_GOT_GPREL_ADD`		|  |
|  | `ld		t1, %got_gprel_lo(ptr)(t1)`	| `R_RISCV_GOT_GPREL_LO12`		| `addi	t1, gp, %gprel_lo(ptr)`	| `R_RISCV_GPREL_I` |
|  | `sd		t0, 0(t1), %got_gprel(ptr)`	| `R_RISCV_GOT_GPREL_STORE`	| `sd	t0, %gprel_lo(ptr)(gp)`	| `R_RISCV_GPREL_S` |
