#include <stdio.h>

static int add(int left, int right) {
    return left + right;
}

int main(void) {
    printf("sum: %d\n", add(20, 22));
    return 0;
}
