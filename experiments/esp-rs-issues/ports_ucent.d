// ports_ucent.d - companion to ports.d. Isolated #137-style ucent fragment.
// Expected to FAIL to compile: `cent`/`ucent` are reserved in D but the
// frontend rejects them (see run.sh). Compiled separately so the rest of
// ports.d still builds.
extern (C) ucent d_issue137_mul128(ucent a, ucent b)
{
    return a * b;
}
