# Gladius
Gladius is an off-chain, non-custodial Dutch auction-based trading platform. It's a fork of [UniswapX](https://blog.uniswap.org/uniswapx-protocol)

# Resources
- [Gladius intergration guide](https://rubicondefi.notion.site/Rubicon-Gladius-Integration-Guide-ee55cbe3ccdf4b88a6780d8ef090599f)
- [UniswapX repo](https://github.com/Uniswap/UniswapX)
- [UniswapX documentation](https://docs.uniswap.org/contracts/uniswapx/overview)
- [Audits](https://github.com/Uniswap/UniswapX/tree/main/audit)

# Changes to the Uniswap X protocol
- Constructors are removed, and changed to `initialize` functions, to make contracts proxy-compatible.
- Instead of `Ownable` `DSAuth` is used for authentication.
