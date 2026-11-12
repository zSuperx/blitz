# Blitz

**B**uilt (this) **L**anguage **I**n **T**yrannical **Z**ig.

Why **T**yrannical? Because it's a cool word that starts with the letter **T**.

## About

This was originally created as a weekend project to learn Zig and finally get
some hands-on experience with the LLVM API. It has since become a fun project
that I hope will someday be usable for actual programming.

Now that this language has been polished a decent bit, I am hence halting work
on Shrimple, my previous compiler, which can be seen
[here](https://github.com/zSuperx/sc4).

## Language Tour

Blitz is a simple systems-level programming language that is syntactically
similar to Rust and Zig, borrowing bits and pieces from each. Let's explore how
it works!

### Variable Declarations

Like Zig, Blitz requires all variables to declare their mutability intent
upfront. 

```
const x = 5;
mut y = 8;
y = 4;
x = 2; // This causes an error, as shown below
```

This verbosity allows the compiler to catch bugs in your code, like writing to
a `const` variable:

```
error: Cannot assign to const variable `x`. Consider changing it to be `mut`. 
test.bl:2:5:
            const x = 5;
            ^~~~~~~


error: Could not compile program due to 1 errors
```

### Expressions

Blitz, like Rust, is mostly expression-based. In fact, there is currently only
1 true statement: the assignment (technically 2 if we distinguish variable
declarations and variable assignments). Unlike C, assignments to a variable (`x
= 5`) do **not** evaluate to a value. However, nearly every other line of code
is an expression.

#### Blocks

All block scopes `{ ... }` are expressions that evaluate to their last line,
making code like the following valid.

```
const x = {
    const a = 34;
    const b = 35;
    a + b
};
// x will evaluate to 69
```

#### If Else

There are no C-style ternary expressions, because `if ... else ...` itself is
an expression!

Like Zig, conditions must be enclosed in parentheses. This is done to avoid
Rust's verbose `{...}` branch syntax. However, the condition can be negated
using a special case `!` outside the `()` for ease of readability and
modification.

```
const x = if (foo) bar else baz;
const y = if !(foo) bar else baz;
```

Because an `if else` can be bound to a variable, whose type must be known at
compile-time, both branches of the `if else` must have the same type. However,
this restriction is lifted if the `if else` expression is being used as a
_statement_, like below:

```
if (foo) {
    functionThatReturnsBool()
} else {
    functionThatReturnsInt()
}
```

### Functions

#### Defining a Function

Now, let's use what we've learned so far to write a function!

Functions can be defined using the familiar `fn` syntax, followed by its name,
typed arguments, and a trailing return type:

```
fn max(a: i32, b: i32): i32 {
    // ...
}

fn do_nothing() {} // omitting a return type implies the function returns `void`
```

To return a value, we can use the `return` keyword. The returned value must
match the type the function expects.

```
fn max(a: i32, b: i32): i32 {
    return if (a > b) a else b;
}
```

If we compile this, we'll see a helpful note in the form of a warning:

```
warning: Unnecessary `return` at the tail of a function. 
test.bl:2:5:
            return if (a > b) a else b;
            ^~~~~~~~~~~~~~~~~~~~~~~~~~
  Consider using the expression without a trailing semicolon.
```

Because the function body itself is a block, and blocks evaluate to their final
expression, the `return` can actually be omitted here!

```
fn max(a: i32, b: i32): i32 {
    if (a > b) a else b
}
```

Perfec! Now that we've written our first function, let's call it!

#### Calling Functions

Calling functions is pretty straightforward. We must provide the correct
number of arguments _and_ the correct type for each argument:

```
fn max(a: i32, b: i32): i32 {
    if (a > b) a else b
}

fn main() {
    const x = max(5, true);
}
```

```
error: Incorrect argument type passed to function. Expected `i32` but got `bool` 
test.bl:6:22:
            const x = max(5, true);
                             ^~~~


error: Could not compile program due to 1 errors
```

### Types

#### Type Inference

Earlier, we saw that Blitz was able to recognize we were passing in the wrong
type (`bool`) to a function that expected an `i32`. This is because of Blitz's
type inference and type checking phase. So while the following code is valid...

```
fn foo(): u8 {
    const x: i64 = 0;
    const y: u8 = 69;
    y
}

fn bar(a: i64) {
    // ...
}
```

...the type annotations on `x` and `y` are actually entirely optional here!

```
fn foo(): u8 {
    const x = 0;    // x is still an `i64`
    const y = 69;   // y is still a `u8`
    y
}

fn bar(a: i64) {
    // ...
}
```

This is because Blitz notices that `x` is passed to `bar`, which expects an
`i64`. Similarly, `y` is returned in a function that expects a `u8`.

If not enough info is given about an integer type, Blitz will default it to a
`u32` or `i32` depending on its usage:

```
fn main() {
    const x = 5;
    const y = -x;
    const z = x + y;
    const w = 0;
}
```

In the above example, even though no type annotations were provided, Blitz
knows that since `x` is negated, it must be signed. Both `y` and `z` follow,
due to their direct relationship to `x`, making all 3 of them resolve to `i32`.
However, `w` has no constraints other than the fact that it's an integer, so it
is assigned the type `u32`.

> [!NOTE] The type inference is in a very early stage. It's the first type
> inference engine I've ever written, so there are bound to be bugs!
> 
> I also plan to add type variables and a concept of generic types in the future!

#### Builtin Types

The Blitz compiler currently recognizes the following builtin types:

1. `i8`, `i16`, `i32`, `i64`, `isize`
2. `u8`, `u16`, `u32`, `u64`, `usize`
3. `bool`
4. `void`

Also, pointers exist. _(Not much to say here since I'm still designing this
part of the language lol)_

_(The `isize` and `usize` types are meant to conform to the system address
width, but for the time being, they are hard-coded to `64` bits.)_

#### Custom Types

_(Coming soon...)_

## Compiler Building & Usage

### Building

Since Blitz is (currently) a frontend for LLVM, `libllvm` is required to build
it, while `clang` is required to compile Blitz's output (LLVM IR) into machine
code. The `flake.nix` in this repository includes a `devShell` that provides
`pkgs.llvmPackages_21.llvm`, which exposes `libllvm.so`. I'm leaving it up to
you to get `clang`.

Once you have the required dependencies, run `zig build` and enjoy your freshly
baked Blitz compiler!

_(I plan on writing a custom code generation backend! I have done some related
work in a previous compiler of mine, which you can find
[here](https://github.com/zSuperx/sc4). Remember, this is still a learning
experience for me!)_

### Compiling Blitz Code

To compile a blitz file, simply call `blitz` with the input file. Currently,
the following command line options are supported:

```
Usage: blitz <FILE> [OPTIONS]

Options:

    -o <PATH>   Specifies the output file to write to (default ./a.out).
```

_(Yeah, there isn't much here yet. I still need to learn how to properly parse
command line args in Zig haha)_

## How I made it

...with great difficulty and struggle, especially since the entire (original)
code generation phase was written while I was drunk.

For historical purposes, this is progress that was made during the original
weekend:
- Lexer + parser. Grammar included:
    - `const` + `mut` variables + compiler warnings when these were
      misused/redundant
    - NO type annotations (everything was implicitly an `i64`)
- Sema and language behavior:
    - Function calls + return statements
    - Variable decls + assignments
    - Mathematical binary operations
    - NO control flow (if/if-else)
- Diagnostics + error reporting
    - Actually good error messages (this was a first for me haha)
- Codegen
    - LLVM lowering support for the full AST (at the time)
    - Driver code to generate LLVM IR and run `clang` to compile it.

As per the Zig philosophy, there is **zero AI generated code in this
repository**. However, a clanker was consulted to sift through `llvm-zig`'s
generated bindings since the names didn't line up with the Kaleidoscope
tutorial. This helped me save some time, but had no effect on the code I wrote
:)

## Credits

* [Shrimple](https://github.com/zSuperx/sc4)
* [Type inference and the Unification
  Algorithm](https://groups.seas.harvard.edu/courses/cs152/2023sp/lectures/lec16-typeinference.pdf)
* [llvm-zig](https://github.com/kassane/llvm-zig)
* [Kaleidoscope: Code generation to LLVM
  IR](https://llvm.org/docs/tutorial/MyFirstLanguageFrontend/LangImpl03.html#kaleidoscope-code-generation-to-llvm-ir)
