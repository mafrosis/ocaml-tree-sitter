How to add support for a new language
==

This is about adding support for a new programming language in
semgrep using the
[tree-sitter](https://tree-sitter.github.io/tree-sitter/)
technology. While new languages should use tree-sitter,
semgrep also supports some languages independently if there's a good
legacy OCaml parser for them. Check for your language in
[pfff](https://github.com/returntocorp/pfff) and if you see it
in there, [talk to us](https://semgrep.dev/docs/support/).
Otherwise, let's get started.

Submodules overview
--

There are quite a few GitHub repositories involved in porting a language.
Here is the file hierarchy of the [semgrep
repository](https://github.com/returntocorp/semgrep):

``` shell
.
└── semgrep
    ├── ocaml-tree-sitter      # runtime library for tree-sitter parsers
    └── semgrep-core
        ├── pfff               # non-tree-sitter parsers
        └── tree-sitter-lang   # generated tree-sitter parsers
            ├── semgrep-java
            ...
            └── semgrep-ruby
```

You'll need a new repo semgrep-X to host the generated parser code.
Ask someone at r2c to create one for you.

Setup
--

As a model, you can use the existing setup for `ruby` or `javascript`. Our
most complicated setup is for `typescript` and `tsx`.

First install `npx` following
[this doc](https://github.com/returntocorp/ocaml-tree-sitter/blob/master/doc/node-setup.md).

### Expedited setup

If you're lucky, the language you want to add can be added with the
script `add-simple-lang`:

```
$ cd lang
$ ./add-simple-lang --help
$ ...  # follow the instructions from --help
```

This often works with languages that define a single dialect using a
`grammar.js` file at the root of the project. If this simplified
approach fails, use the **Manual setup** instructions below to understand
what's going on or to set things up manually.

### Manual setup

From the ocaml-tree-sitter repo, do the following:

1. Create a `lang/X` folder.
2. Make a `test/ok` directory. Inside the directory,
   create a simple `hello-world` program for the language you are porting.
   Name the program `hello-world.<ext>`.
3. Now make a file called `extensions.txt` and input all the language extensions
   (.rb, .kt, etc) for your language in the file.
4. Create a file called `fyi.list` with all the information files, such as
    `semgrep-grammars/src/tree-sitter-X/LICENSE`,
    `semgrep-grammars/src/tree-sitter-X/grammar.js`,
    `semgrep-grammars/src/semgrep-X/grammar.js`, etc.
   to bundle with the final OCaml/C project.
5. Link the Makefile.common to a Makefile in the directory with:
   `ln -s ../Makefile.common Makefile`
6. Create a test corpus. You can do this by:
   * Running `most-starred-for-language` in order to gather projects
     on which to run parsing stats. Run with the following command:
     `./scripts/most-starred-for-language <lang> <github_username> <api_key>`
   * Using github advanced search to find the most starred or most forked repositories.
7. Copy the generated `projects.txt` file into the `lang/X` directory.
8. Add in extra projects and extra input sets as you see necessary.

Here's the file hierarchy for Ruby:

```shell
lang/ruby               # language name of the form [a-z][a-z0-9]*
├── extensions.txt      # standard name. Required for stats.
├── fyi.list            # list of informational files to copy. Recommended.
├── Makefile -> ../Makefile.common
├── projects.txt        # standard name. Required for stats.
└── test                # sample input files
    ├── ok              # contains input files supported by the current grammar
    │   ├── comment.rb
    │   ├── ex1.rb
    │   ├── ex2.rb
    │   ├── hello.rb
    │   └── poly.rb
    └── xfail            # contains input files that are expected to fail
        └── rating.rb
```

To test a language in ocaml-tree-sitter, you must build the
ocaml-tree-sitter OCaml code generator, run it to produce a parser,
then run some tests for the parser. Full instructions for this
are given in [updating-a-grammar](updating-a-grammar.md) under
"Testing". The short instructions are:
1. For the first time, build everything with `./scripts/rebuild-everything`.
2. Subsequently, work from the `lang/X` folder and run
   `make` and `make test`.

### The `fyi.list` file

The `fyi.list` file was created to specify informational files that
should accompany the generated files. These files are typically:

* the source grammar, most often a single `grammar.js` file.
* the licensing conditions usually specified in a `LICENSE` file.

Example:

```
# Comments are allowed on their own line.
# Blank lines are ok.

# Each path is relative to ocaml-tree-sitter/lang
semgrep-grammars/src/tree-sitter-ruby/LICENSE
semgrep-grammars/src/tree-sitter-ruby/grammar.js
semgrep-grammars/src/semgrep-ruby/grammar.js
```

The files listed in `fyi.list` end up in a `fyi` folder in
tree-sitter-lang. For example,
[see `ruby/fyi`](https://github.com/returntocorp/semgrep-ruby/tree/main).

Extending the original grammar with semgrep syntax
--

This is best done after everything else is set up. Some constructs
such as semgrep metavariables (`$FOO`) may already be valid constructs
in the language, in which case there's nothing to do. Some support for
the semgrep ellipsis `...` usually needs to be added as well.

You'll need to learn [how to create tree-sitter
grammars](https://tree-sitter.github.io/tree-sitter/creating-parsers).

1. Work from `semgrep-grammars/src/semgrep-X` and use `make` and
   `make test` to build and test.
2. Add new test cases to `test/corpus/semgrep.text`.
3. Edit `grammar.js`.
4. Refer to the original grammar in
   `semgrep-grammars/src/tree-sitter-X` to determine which rules to
   extend.

For an example of how to extend a language, you can:
* Look at what was done for the semgrep extensions of other languages
  in their respective `semgrep-*` folders.
* Look at how tree-sitter-typescript extends the javascript grammar.
  This is the file `common/define-grammar.js` in the
  tree-sitter-typescript repo.

Avoiding parsing conflicts is the trickiest part. Asking for help is
encouraged.

Parsing statistics
--

From a language's folder such as `lang/csharp`, two targets are
available to exercise the generated parser:

* `make test`: runs on `test/ok` and `test/xfail`
* `make stat`: downloads the code specified in `projects.txt` and
  parses the files whose extension matches those in `extensions.txt`,
  reporting parsing success in the form of a CSV file.

For gathering a good test corpus, you can use [GitHub
Search](https://github.com/search/advanced) or the script provided in
`scripts/most-starred-for-language.py`. For github searches, filter by
programming language and use a constraint to select large projects,
such as "> 100 forks". Collect the repository URLs and put them into
`projects.txt`.

Publishing generated parsers
--

After you have pushed your ocaml-tree-sitter changes to the main
branch, do the following:
1. In `ocaml-tree-sitter/lang/Makefile`, add language under
   'SUPPORTED_LANGUAGES' and 'STAT_LANGUAGES'.
2. In `ocaml-tree-sitter/lang` directory, run `./release X`. This will
   automatically add code for parsing to `semgrep-X`.

### Troubleshooting

Various errors can occur along the way.

Compilation errors in C or C++ are usually due to a missing source
file `scanner.c` or `scanner.cc`, or a grammar with a name that
doesn't match the name inside the scanner file. Javascript files may
also be missing, in particular in the case of grammars that extend
existing grammars such as C++ for C or TypeScript for
JavaScript. Check for `require()` calls in `grammar.js` and learn how
this NodeJS primitive resolves paths.

There may also be errors when generating or compiling
OCaml code. These are likely bugs in ocaml-tree-sitter and they should
be reported or fixed right away.

Here are some known types of parsing errors:

* A syntax error. The input program is in the wrong syntax or uses a
  recent feature that's not supported yet: `make test` or directly the
  `parse_X` program will show the tree produced by tree-sitter with
  one or more `ERROR` nodes.
* A "reparsing" error. It's an error generated after the first
  successful parsing pass by the tree-sitter parser, during the
  reparsing pass by the OCaml code performed by the generated
  `Parse.ml` file.  The error message should tell you something like
  "cannot interpret tree-sitter's output", with details on what code
  failed to match what pattern. This is most likely a bug in
  ocaml-tree-sitter.
* A segmentation fault. This could be due to a bug in the
  OCaml/tree-sitter C bindings and should be fixed. A simple test case
  that reproduces the problem would be nice.
  See https://github.com/returntocorp/ocaml-tree-sitter/issues/65

Parsing errors that are due
to an incomplete or incorrect grammar should be recorded, and
eventually reported and/or fixed in the upstream project.
We keep failing test cases in a `fail/` folder, preferably in the form
of the minimal program suitable for a bug report, with a comment
describing what was expected and what's going on.

<!-- TODO: move the following sections to semgrep/doc/ -->

## pfff

Pfff defines a list programming languages, some of which have parsers
in pfff itself. Others are tree-sitter parsers which are otherwise
independent from pfff. You need to add the new language to the list of
languages in pfff.

Look under **Adding a Language** in [pfff](https://github.com/returntocorp/pfff/blob/develop/README.md)
for step-by-step instructions.

## semgrep-core

After pfff has been updated, you need to add these changes into semgrep-core.
Follow the instructions specified in `/doc/port-language.md`.
<!-- TODO: said instructions are likely to change and go unmaintained.
     Better focus on explaining what's going on so the reader doesn't get
     stuck due to an incorrect instruction.
-->

## Legal concerns

Be thankful for the authors of the original code, keep clearly visible
license notices, and make it easy to get back to the original projects:

* Make sure to preserve the `LICENSE` files. This should be listed in
  the `fyi.list` file.
* For sample input in `test/`, consider Public Domain ("The
  Unlicense") files or write your own, for simplicity.
  [GitHub Search](https://github.com/search/advanced)
  allows you to filter projects by license and by programming language.

## See also

[How to upgrade the grammar for a language](updating-a-grammar.md)
