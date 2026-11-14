#ifndef Instruction

#define Instruction
#include <vector>
namespace tt06{
enum OperandType{
    GPIO_loc,
    bit,
    bit_loc,
    addr  
};
enum OperandMnemonic{
    wait,
    shift,
    setBit,
    jmp
};
struct Operand{
    OperandType type;
    int value;
};
struct Instr{
    OperandMnemonic mnemonic;
    std::vector<Operand> operands;
    int fileAddress;
};
#endif // !Instruction
}
