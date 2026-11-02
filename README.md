# zb

I don't yet have a great name for this, so for the time being I'm going to call
it ZB = Zig Baby.

This was created as a weekend project to learn Zig and finally get some
hands-on experience with the LLVM API.

# Language

ZB is similar to B. It currently has only 1 type: `u64`. There are no type
annotations, as every type is inferred to be a `u64`.

_(I will add more types + an actual type checking phase later when I get time.)_

Here is some example zb code (there is no control flow yet haha):
```
fn add(a, b) {
  return a + b;
}

fn main() {
  let a = 5;
  let b = 6;
  return add(a, b);
}
```

# Compiler Usage

Since zb is just a frontend for LLVM, `llvm` is required to both build and run
this compiler. The `flake.nix` includes a devShell that provides
`pkgs.llvmPackages_21.llvm`, which exposes `libllvm.so`, `llc`, and `opt`.

_(I will implement a custom backend when I get time)_

# How I made it

...with great difficulty and struggle. Also much of this compiler was written
while I was drunk lol.

Also as per the Zig philosophy, there is zero AI generated code in this
repository. However, I did use it to sift through `llvm-zig`'s generated
bindings since the names didn't line up with the Kaleidoscope tutorial, which
was kind of annoying.

# Credits

* [llvm-zig](https://github.com/kassane/llvm-zig)
* [Kaleidoscope: Code generation to LLVM IR](https://llvm.org/docs/tutorial/MyFirstLanguageFrontend/LangImpl03.html#kaleidoscope-code-generation-to-llvm-ir)
