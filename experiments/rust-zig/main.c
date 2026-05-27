#include "semihost.h"
extern int rs_check_u128(void);
int xmain(void){
    int ok = rs_check_u128();
    puts_("\nRust<->Zig u128 FFI (C can't express u128 on xtensa):\n  ");
    puts_(ok==1 ? "rs_check_u128 = 1  OK (carry across 4 words, cross-language)\n"
                : "rs_check_u128 = 0  FAIL\n");
    sys_exit(ok==1 ? 0 : 1); return 0;
}
