# Gladius
Gladius is an off-chain, non-custodial Dutch auction-based trading platform. It's a fork of [UniswapX](https://blog.uniswap.org/uniswapx-protocol)

# ✍🏻 Scope

The following contracts are considered in scope for this audit. **<TODO: LINK PUBLIC CODEBASE>**, *note that it includes some contracts outside of scope for helpful reference and for the testing suite to work.*

| Contracts in-scope destinations |
| --- |
| src/reactors/BaseGladiusReactor.sol |
| src/reactors/GladiusReactor.sol |
| src/lib/PartialFillLib.sol |
| src/fee-controllers/RubiconFeeController.sol |
| src/lens/GladiusOrderQuoter.sol |
| src/lib/DSAuth.sol |
| src/lib/ProxyConstructor.sol |

**SLOC** for *contracts in-scope*

| Contract | SLOC | Purpose | 
| --- | --- | --- |
| BaseGladiusReactor | 161 | Abstract contract, that contains all the main functionality, that shall be implemented by higher-level gladius reactors.|
| GladiusReactor | 95 | Contains logic for settling off-chain orders and allows to partially fill them.|
| PartialFillLib | 98 | Implements the main partial fill logic, that’s used in resolve function of GladiusReactor|
| RubiconFeeController | 88 | Contains fee logic, that’s executed on each order settlement. | 
| GladiusOrderQuoter | 45 | Meant to be used as an off-chain lens contract to pre-validate generic gladius orders. |
| DSAuth | 23 | Ownable but without constructor. |
| ProxyConstructor | 6 | Contains constructor-like functions to properly wrap contracts in proxy. | 

**Total nSLOC: 516** ([calculated with this plugin.](https://github.com/ConsenSys/solidity-metrics))

# 👷🏻‍♂️Installation

```bash
git clone <LINK TO THE PUBLIC REPO>
# Install deps
forge install
# Run ONLY Gladius tests
forge test --match-contract "PartialFillLib|RubiconFeeControllerTest|GladiusReactor"
```

# 👀 Additional context

- `GladiusReactor` is based on UniswapX’s `ExclusiveDutchOrderReactor` and intended to support `ExclusiveDutchOrders`.

# 📄 Contracts overview

### PartialFillLib

The main library that implements partial execution of an order and contains `GladiusOrder` struct - which, essentially, is an `ExclusiveDutchOrder` with an additional `fillThreshold` parameter, that allows swappers to set a minimum threshold for a partial fill execution.

```solidity
struct GladiusOrder {
    // Generic order information.
    OrderInfo info;
    // The time at which the 'DutchOutputs' start decaying.
    uint256 decayStartTime;
    // The time at which price becomes static.
    uint256 decayEndTime;
    // The address who has exclusive rights to the order until 'decayStartTime'.
    address exclusiveFiller;
    // The amount in bps that a non-exclusive filler needs to improve the outputs by to be able to fill the order.
    uint256 exclusivityOverrideBps;
    // The tokens that the swapper will provide when settling the order.
    DutchInput input;
    // The tokens that must be received to satisfy the order.
    DutchOutput[] outputs;
    // Minimum amount of input token, that can be partially filled by taker.
    uint256 fillThreshold;
}
```

`partition` function is executed during order’s resolution, it mutates input and output amounts by replacing input amount with `quantity` and calculating output amount, based on the initial exchange rate.

```solidity
...
uint256 outPart = quantity.mulDivUp(output[0].amount, input.amount);
...
// Mutate amounts in structs.
input.amount = quantity;
output[0].amount = outPart;
```

### BaseGladiusReactor

Base reactor logic for settling off-chain signed orders, using arbitrary fill methods specified by fillers. `BaseGladiuReactor` implements 8 `execute*` entry-points, capturing an execution flow of these functions and leaving implementation of `resolve` and `transferInputTokens` functions to higher-level reactors.

There are 2 variations of the `execute*` entry point, with the first one representing the basic `execute` and the second one overloading it with the additional `quantity` parameter, which allows `fillers` to execute orders partially (as long as `fillThreshold` allows it as well).

```solidity
//------------- Only full execution of an 'order'
function execute(SignedOrder calldata order) external
function executeWithCallback(SignedOrder calldata order, bytes calldata callbackData) external
function executeBatch(SignedOrder[] calldata orders) external
function executeBatchWithCallback(SignedOrder[] calldata orders, bytes calldata callbackData) external

//------------- Either full or partiall execution of an 'order'
function execute(SignedOrder calldata order, uint256 quantity) external payable override nonReentrant {
function executeWithCallback(SignedOrder calldata order, uint256 quantity, bytes calldata callbackData) external
function executeBatch(SignedOrder[] calldata orders, uint256[] calldata quantities) external
function executeBatchWithCallback(SignedOrder[] calldata orders, uint256[] calldata quantities, bytes calldata callbackData) external
```

### GladiusReactor

Inherits `BaseGladiusReactor` and implements `resolve`(x2) and `transferInputTokens` functions. `GladiusReactor` resolves an ABI-encoded `GladiusOrder` into generic `ResolvedOrder` applying `decay` and `partition` functions alongside. Basically, it treats incoming order as an `ExclusiveDutchOrder`, that can be executed not only fully, but also partially.

### RubiconFeeController

Applies a fee on each order executed through `GladiusReactor`. `RubiconFeeController` has 2 types of fees - base fee, that is applied on each pair by default, and a pair-based fee, that will be used for a specific pair replacing the base fee, once enabled.

# Additional Resources
- [Gladius intergration guide](https://rubicondefi.notion.site/Rubicon-Gladius-Integration-Guide-ee55cbe3ccdf4b88a6780d8ef090599f)
- [UniswapX repo](https://github.com/Uniswap/UniswapX)
- [UniswapX documentation](https://docs.uniswap.org/contracts/uniswapx/overview)
- [UniswapX audits](https://github.com/Uniswap/UniswapX/tree/main/audit)
