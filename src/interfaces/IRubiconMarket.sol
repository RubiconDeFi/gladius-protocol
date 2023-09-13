// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

interface IRubiconMarket {
    function cancel(uint256 id) external;

    function offer(
        uint256 pay_amt, //maker (ask) sell how much
        IERC20 pay_gem, //maker (ask) sell which token
        uint256 buy_amt, //maker (ask) buy how much
        IERC20 buy_gem, //maker (ask) buy which token
        uint256 pos, //position to insert offer, 0 should be used if unknown
        bool matching //match "close enough" orders?
    ) external returns (uint256);

    function getBestOffer(
        IERC20 sell_gem,
        IERC20 buy_gem
    ) external view returns (uint256);

    function getFeeBPS() external view returns (uint256);

    function getOffer(
        uint256 id
    ) external view returns (uint256, IERC20, uint256, IERC20);

    function getBuyAmountWithFee(
        IERC20 buy_gem,
        IERC20 pay_gem,
        uint256 pay_amt
    ) external view returns (uint256 buy_amt, uint256 approve_amount);

    function getPayAmountWithFee(
        IERC20 pay_gem,
        IERC20 buy_gem,
        uint256 buy_amt
    ) external view returns (uint256 pay_amt, uint256 approve_amount);

    function sellAllAmount(
        IERC20 pay_gem,
        uint256 pay_amt,
        IERC20 buy_gem,
        uint256 min_fill_amount
    ) external returns (uint256 fill_amt);

    function buyAllAmount(
        IERC20 buy_gem,
        uint256 buy_amt,
        IERC20 pay_gem,
        uint256 max_fill_amount
    ) external returns (uint256 fill_amt);
}
