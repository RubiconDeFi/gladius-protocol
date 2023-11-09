# Changes to the Uniswap X protocol

- Constructors are removed, and changed to `initialize` functions, to make contracts proxy-compatible.
- Instead of `Ownable` `DSAuth` is used for authentication.
