#ifndef Instruction

#define Instruction
#include <vector>
namespace tt06{
enum OperandType{
    GPIO_loc,
    bit,
    bit_loc,
    timer_loc,
    addr,
};
enum Mnemonic{
    waitVal,
    waitTimer,
    shift,
    setBit,
    jmp,
    Wait_timer
};
struct Operand{
    OperandType type;
    int value;
};
struct Instr{
    Mnemonic mnemonic;
    std::vector<Operand> operands;
    int fileAddress;
};
#endif // !Instruction
}
