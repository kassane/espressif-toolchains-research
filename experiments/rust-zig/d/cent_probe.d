// Compile-time probe: try to use the `cent` keyword as a type. Expected to
// fail with the exact error captured in run.sh §(D-1).
module cent_probe;
extern (C):
int probe() { cent x = 1; return cast(int)x; }
