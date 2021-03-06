// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "./Ownable.sol";


/**
 * @title Destructible
 * @dev Base contract that can be destroyed by owner. All funds in contract will be sent to the owner.
 */
contract Destructible is Ownable {
    /**
    * @dev Transfers the current balance to the owner and terminates the contract.
    */
    function destroy() public onlyOwner {
        selfdestruct(owner());
    }

    function destroyAndSend(address payable _recipient) public onlyOwner {
        selfdestruct(_recipient);
    }
}
