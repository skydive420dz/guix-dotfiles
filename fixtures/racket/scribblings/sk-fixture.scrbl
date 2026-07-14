#lang scribble/manual

@(require (for-label racket/base
                     sk/fixture/main))

@title{Marked Racket Project Fixture}

This small collection proves that source lookup, RackUnit, macro expansion,
and Scribble all work from the authenticated project shell without installing
the project into a mutable Racket catalog.

@defmodule[sk/fixture/main]

@defproc[(fixture-add [left number?] [right number?]) number?]{
Returns the sum of @racket[left] and @racket[right].}

@defproc[(fixture-double [value number?]) number?]{
Returns twice @racket[value].}

@defproc[(fixture-answer) exact-integer?]{
Returns @racket[42].}

@defform[(with-fixture-answer identifier body ...)]{
Binds @racket[identifier] to @racket[(fixture-answer)] while evaluating the
@racket[body] forms.}
