// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

/**********************************************************************


████████╗██╗░░░░░██████╗░░██████╗████████╗░█████╗░██╗░░██╗██╗███╗░░██╗░██████╗░
╚══██╔══╝██║░░░░░██╔══██╗░██╔════╝╚══██╔══╝██╔══██╗██║░██╔╝██║████╗░██║██╔════╝░
░░░██║░░░██║░░░░░██████╦╝░░╚█████╗░░░░██║░░░███████║█████═╝░██║██╔██╗██║██║░░██╗░
░░░██║░░░██║░░░░░██╔══██╗░░░╚═══██╗░░░██║░░░██╔══██║██╔═██╗░██║██║╚████║██║░░╚██╗
░░░██║░░░███████╗██████╦╝░░██████╔╝░░░██║░░░██║░░██║██║░╚██╗██║██║░╚███║╚██████╔╝
░░░╚═╝░░░╚══════╝╚═════╝░░░╚═════╝░░░░╚═╝░░░╚═╝░░╚═╝╚═╝░░╚═╝╚═╝╚═╝░░╚══╝░╚═════╝░

********************************************************************** */


import "./lib/HRC20.sol";
import "./lib/SafeMath.sol";
import "./lib/Math.sol";
import "./lib/TransferHelper.sol";


contract TLBStaking is HRC20("TLB Staking", "TLB", 4, 48000 * 365 * 2 * (10 ** 4)) { 
    using SafeMath for uint256;
    event BuyOrderAdded(address guest, uint amount);
    event BuyOrderCancelled(address guest, uint amount);
    event SellOrderAdded(address guest, uint amount);
    event SellOrderCancelled(address guest, uint amount);

    enum NodeType{ PNode, Shareholder, Guest }
    enum MineType{ Flexible, Fixed }
    

    struct Tier {
        uint8 index;
        uint min;
        uint8 staticRewards;
        uint8 sprigs;
        uint limit;
    }

    struct FundLog {
        uint time;
        uint balance;
        int change;
        uint tier;
    }
    
    struct Branch {
        address child;
        uint time; // After filling 3 referees, set it to block time
    }

    
    struct Admin {
        address account;
        uint rewards;
        FundLog[] logs;
        uint totalRewards;
    }
    
    struct Node {
        uint32 position; // location in prism
        uint16 layer; // location in prism
        address referer;
        NodeType role;
        uint8 tier;
        uint totalDeposit;
        uint totalWithdrawal;
        bool isOverflowed; // calculate statically + dynamically(for 1999, 2000, 2001 layer)
        uint lastAmount;
        uint lastTime;
        uint limit;
        uint balance;
        uint rewards; // for shareholder 4% or position rewards, calculate statically and dynamically(999~1001) 
        // uint staticRewards; // calculate dynamically
        // uint dynamicRewards;; // calculate dynamically
        address parent;
        
        // for MLM Tree
        uint16 referalCount;
        Branch[] branches; // first child address (may be not his referee) in every branch
        
        // will save all history to calculate dynamicRewards dynamically
        FundLog[] logs;
        
    }
    
    struct Miner {
        MineType mineType;
        address referer;
        uint tier;
        uint lastBlock;
        uint rewards;
    }
    struct MinerInfo {
        address account;
        uint tier;
    }
    struct ChildInfo {
        address account;
        uint deposit;
    }
    struct MinePool {
        uint totalPower;
        uint minerCount;
        uint minedTotal;
    }

    struct Order {
        uint time;
        address account;
        uint initial;
        uint balance;
    }
    struct OrderTx {
        uint txid;
        uint8 txtype;
        uint quantity;
        uint time;
    }
    
    Admin _admin;
    Admin _zhang;
    Admin _lee;

    uint public totalBurnt = 0;
    address USDTToken = 0xE5f2A565Ee0Aa9836B4c80a07C8b32aAd7978e22;
    uint8 USDTPrecision = 2;
    uint _usdt = uint(10) ** USDTPrecision;

    /* address USDTToken = 0x5e17b14ADd6c386305A32928F985b29bbA34Eff5; //0xFedfF21d4EBDD77E29EA7892c95FCB70bd27Fd28;
    uint8 USDTPrecision = 6; */
    
    // heco mainnet 
    // address USDTToken = 0xa71EdC38d189767582C38A3145b5873052c3e47a;
    // uint8 USDTPrecision = 18;
        
    uint _tpsIncrement = _usdt / 100;
    uint public price = _usdt / 10;
    uint32 public maxUsers = 500500+499500;
    uint32 public totalUsers = 0;
    uint16 public currentLayer = 0;
    uint16 _positionInLayer = 0;
    bool _insuranceStatus = false;
    
    uint public totalMineable = 28032000;
    
    uint public totalDeposit = 0;
    
    
    struct Insurance {
        uint time;
        uint amount;
        uint count;
    }
    Insurance[] insurLogs;
    
    uint8[][] sprigs = [
        [1, 1, 200],
        [2, 2, 150],
        [3, 7, 100],
        [8, 15, 50],
        [16, 20, 20]
    ];
    
    address public firstAddress; // by admin
    
    mapping(uint32 => address) private _prism;
    mapping(address => Node) private _nodes;
    
    Tier[] _tiers;
    
    address public redeemAddress; // 1.5% redeem
    uint public redeemAmount; // 1.5% redeem
    uint _controlAmount; // 1.5% redeem
    
    FundLog[] _inLogs; // all deposit logs;
    FundLog[] _totalLogs;
    FundLog[] _luckyLogs;  // for 999 ~ 1001 layers;

    uint[][] _minerTiers = [
        [15000 * 10 ** uint(USDTPrecision), 100, 100, 30],
        [7500 * 10 ** uint(USDTPrecision), 50, 50, 20], 
        [3500 * 10 ** uint(USDTPrecision), 25, 25, 10], 
        [100 * 10 ** uint(USDTPrecision), 5, 10, 5]
    ];

    
    address[] _minerlist;
    mapping(address=>Miner) _miners;
    mapping(address=>address[]) _referedMiners;
    
    MinePool minePool;
    Order[] _buyBook;
    Order[] _sellBook;
    OrderTx[] _txBook;
    
    
    
    
    constructor () public {
        uint _initialSupply  = maxSupply() * 20 / 100;
        _mint(msg.sender, _initialSupply);
        
        _tiers.push(Tier({
            index: 1,
            min: 200,
            staticRewards: 16,  // 0.1%
            sprigs: 2,
            limit: 2200        // 0.1%
        }));
        _tiers.push(Tier({
            index: 2,
            staticRewards: 12,
            min: 1001,
            sprigs: 3,
            limit: 2100        // 0.1%
        }));
        _tiers.push(Tier({
            index: 3,
            staticRewards: 10,
            min: 2001,
            sprigs: 4,
            limit: 2000        // 0.1%
        }));
        _tiers.push(Tier({
            index: 4,
            staticRewards: 8,
            min: 5001,
            sprigs: 5,
            limit: 1900        // 0.1%
        }));
    }
    function setAdmin(address admin,address lee,address zhang,address redeem) public {
        _admin.account = admin;
        _lee.account = lee;
        _zhang.account = zhang;
        redeemAddress = redeem;
    }
    /**
     * @dev Returns Admin address.
     */
    function admin() public view returns(address) {
        return _admin.account;
    }
    
    /**
     * @dev Returns zhang address.
     */
    function zhang() public view returns(address) {
        return _zhang.account;
    }
    /**
     * @dev Returns Admin address.
     */
    function lee() public view returns(address) {
        return _lee.account;
    }
    
    /**
     * internal
     * @dev Returns tier index corresponding to deposit amount.
     */
    function getTier(uint amount) internal view returns(uint) {
        uint senderTier = 0;
        for(uint i=0; i<_tiers.length;i++) {
            uint iTier = _tiers.length - i;
            Tier storage tier = _tiers[_tiers.length - i - 1];
            if (amount>tier.min) {
                senderTier = iTier;
                break;
            }
        }
        return senderTier;
    }
    
    /**
     * internal
     * @dev indicates the referal link is valid or not.
     */
    function isValidReferer(address sender, address referer) internal view returns(bool) {
        if (_nodes[referer].lastAmount == 0) return false;
        if (_nodes[sender].lastAmount == 0) return true;
        return _nodes[sender].referer==referer;
    }
    
    /**
     * internal
     * @dev indicates the node is exist or not.
     */
    function existNode(address sender) internal view returns(bool) {
        return _nodes[sender].lastAmount > 0;
    }
    
    /**
     * @dev Return required number of TPS to member.
     */
    function _neededTPSForDeposit(uint amount) public view returns(uint256) {
        return amount /  10 / price; // 10% TPS of amount
    }
    /**
     * @dev Return required number of TPS to member.
     */
    function _neededTPSForWithdraw(address account) public view returns(uint256) {
        if (account==_zhang.account || account==_lee.account || account==_admin.account) return 0;
        return _nodes[account].layer<1001 ? 5 : 2;
    }
    /**
     * internal
     * @dev Logically add users to prism.
     * At this time, if the current layer is filled by the user, the number of layers and the price of TPS tokens will change.
     */
    function addUserToPrism() internal returns(uint32) {
        uint32 maxUsersInLayer = currentLayer < 1001 ? currentLayer : 2000 - currentLayer;
        if (maxUsersInLayer == _positionInLayer) {
            currentLayer++;
            price = SafeMath.add(price,_tpsIncrement);
            _positionInLayer = 1;
        } else {
            _positionInLayer++;
        }
        totalUsers++;
        return totalUsers;
    }
    
    
    /**
     * internal
     * @dev returns last node in branch.
     */
    function getLastInBranch(address parent) internal returns(address){
        Node storage parentNode = _nodes[parent];
        if (parentNode.branches.length==0) {
            return parent;
        } else {
            return getLastInBranch(parentNode.branches[0].child);
        }
    }
    
    /**
     * internal
     * @dev returns shareholder of linked chain of sender.
     */
    function getShareholderInBranch(address parent) internal returns(address){
        Node storage parentNode = _nodes[parent];
        if (parentNode.role==NodeType.Shareholder) {
            return parent;
        } else {
            return getShareholderInBranch(parentNode.parent);
        }
    }
    
    /**
     * internal
     * @dev Add or update a node when a user is deposited into the pool.
     */
    function updateNodeInDeposit(address sender,address referalLink, uint amount, uint time) internal {
        Node storage node = _nodes[sender];
        Node storage refererNode = _nodes[referalLink];
        if (!existNode(sender)) {
            uint32 position = addUserToPrism();
            address parent;
            if (totalUsers==1) {
                node.role = NodeType.PNode;
                firstAddress = sender;
                parent = referalLink;
            } else if (currentLayer<5) {
                parent = referalLink;
                node.role = NodeType.Shareholder;
                _nodes[parent].branches.push(Branch(sender,time));
            } else {
                node.role = NodeType.Guest;
                uint16 countBranch = refererNode.referalCount / 3;
                uint16 remainInBranch = refererNode.referalCount % 3;
                if (remainInBranch==0) {
                    parent = referalLink;
                    if (countBranch>0) {
                        _nodes[parent].branches[countBranch-1].time = now;
                    }
                    _nodes[parent].branches.push(Branch(sender,0));
                } else {
                    parent = getLastInBranch(referalLink);
                }
            }
            
            refererNode.referalCount++;
            
            
            node.referer = referalLink;
            node.position = position;
            node.layer = currentLayer;
            node.balance = amount;
            
            node.isOverflowed = false;
            node.rewards = 0; // for shareholder
            // node.staticRewards = 0;
            // node.dynamicRewards = 0;
            node.parent = parent;
            node.referalCount = 0;
            if (position > 502503) { // save prism position from 1002 layer
                _prism[position] = sender;
            }
        } else {
            node.balance += amount;
        }
        node.totalDeposit += amount;
        totalDeposit += amount;
        uint8 tier = (uint8)(getTier(node.balance));
        node.limit = node.balance * _tiers[tier-1].limit / 1000;
        node.tier = tier;
        if (node.isOverflowed) node.isOverflowed=false;
        redeemAmount += amount * 18 / 1000; // 1.5%
        _controlAmount += amount * 32 / 1000; // 1.5%
        _admin.rewards += amount * 20 / 1000; // 2%
        _zhang.rewards += amount * 15 / 1000; // 1.5%
        _lee.rewards += amount * 15 / 1000; // 1.5%
        
        if (node.role == NodeType.Guest) {
            Node storage shareholderNode;
            if (refererNode.role==NodeType.Shareholder) {
                shareholderNode = refererNode;
            } else {
                address shareholder = getShareholderInBranch(referalLink);
                shareholderNode = _nodes[shareholder];
            }
            shareholderNode.rewards += amount * 40 / 1000; // 4%;
        }
            
        node.lastAmount = amount;
        node.lastTime = time;
        uint lenLogs = node.logs.length;
        if (lenLogs==0) {
            node.logs.push(FundLog({
                time: time,
                tier: node.tier,
                balance: node.balance,
                change: (int)(amount)
            }));
        } else {
            FundLog storage plog = node.logs[lenLogs-1];
            if (now - plog.time < 86400 && plog.change>0) {
                plog.balance += amount;
                plog.tier += node.tier;
                plog.change += (int)(amount);
                plog.time = now;
            } else {
                node.logs.push(FundLog({
                    time: time,
                    tier: node.tier,
                    balance: node.balance,
                    change: (int)(amount)
                }));
            }
        }
        
        // Versicherung Auslösemechanismus Gesamtbetrag alle 36 Stunden.
        uint len = _totalLogs.length;
        uint roundedtime = now - (now % 129600);
        if (len==0) {
            _totalLogs.push(FundLog({
                time:roundedtime,
                balance:amount,
                change:0,
                tier:0
            }));
        } else {
            uint balance = SafeMath.add(_totalLogs[len-1].balance,amount);
            if (_totalLogs[len-1].time==roundedtime) {
                _totalLogs[len-1].balance = balance;
            } else {
                // check insurance 
                uint increament = (_totalLogs[len-1].balance - _totalLogs[len-2].balance) * 1000 / _totalLogs[len-1].balance; 
                if (increament<20) {
                    uint logtime = _totalLogs[len-1].time;
                    if (insurLogs.length==0 || logtime>insurLogs[insurLogs.length-1].time) {
                        uint count = 0;
                        len = _inLogs.length;
                        for(uint i=len-1; i>=0; i++) {
                            uint diff = logtime - _inLogs[len-1].time;
                            if (diff>0 && diff<7200) count++;
                        }
                        insurLogs.push(Insurance({
                            time: logtime,
                            amount: totalUsdtBalance() * 50 / 1000,
                            count:count
                        }));    
                    }
                }
                _totalLogs.push(FundLog({
                    time:roundedtime,
                    balance:balance,
                    change:0,
                    tier:0
                }));
            }
        }
        _inLogs.push(FundLog({
            time: time,
            tier: 0,
            balance: amount,
            change: 0
        }));
    }
    function totalUsdtBalance() public view returns(uint) {
        return IHRC20(USDTToken).balanceOf(address(this));
    }
    function _withdrawal(address sender, uint time) internal returns(uint) {
        uint withdrawable = 0;
        if (sender==_admin.account) {
            withdrawable = _admin.rewards + dynamicRewardOf(sender);
            _admin.rewards = 0;
            _admin.logs.push(FundLog({
                time: time,
                tier: 4,
                balance: 0,
                change: -(int)(withdrawable)
            }));
        } else if (sender==_zhang.account) {
            withdrawable = _zhang.rewards;
            _zhang.rewards = 0;
            _zhang.logs.push(FundLog({
                time: time,
                tier: 4,
                balance: 0,
                change: -(int)(withdrawable)
            }));
        } else if (sender==_lee.account) {
            withdrawable = _lee.rewards;
            _lee.rewards = 0;
            _lee.logs.push(FundLog({
                time: time,
                tier: 4,
                balance: 0,
                change: -(int)(withdrawable)
            }));
        } else {
            Node storage node = _nodes[sender];
            if (node.balance>0) {
                (bool overFlowed,uint staticRewards,uint dynamicRewards,uint rewards) = allRewardOf(sender);
                require(!overFlowed, "# Overflowed");
                uint _benefit = staticRewards + dynamicRewards;
                if (node.layer<5) {
                    withdrawable = _benefit * 850 / 1000 + rewards;
                } else if (node.layer>998) {
                    withdrawable = (_benefit + rewards) * 850 / 1000;
                } else {
                    withdrawable = _benefit * 850 / 1000;
                }
                
                uint half = (_benefit + rewards) / 2;
                if (node.balance > half) {
                    node.balance -= half;
                    uint8 tier = (uint8)(getTier(node.balance));
                    if (tier!=node.tier) {
                        node.tier = tier;
                        node.limit = node.balance * _tiers[tier-1].limit / 1000;
                    } else {
                        node.limit -= half;
                    }
                } else {
                    node.tier = 0;
                    node.balance = 0;
                    node.limit = 0;
                }
                // Symmetrische Positionsbelohnung
                if (node.layer<999) {
                    uint pos = _benefit * 75 / 1000; 
                    address posAddr = _prism[1999];
                    if (posAddr!=address(0)) {
                        Node storage posNode = _nodes[sender];    
                        posNode.rewards += pos;
                    }
                    // Belohnung für jede Position 999-1000-1001 (insgesamt 2998 Personen)
                    _luckyLogs.push(FundLog({
                        time:time,
                        balance:pos,
                        change:0,
                        tier:0
                    }));
                } else {
                    redeemAmount += _benefit * 150 / 1000;
                }
            }
        }
        return withdrawable;
    }
    function _withdrawable(address sender, uint time) internal view returns(uint) {
        uint withdrawable = 0;
        uint _benefit = 0;
        if (sender==_admin.account) {
            _benefit = _admin.rewards + dynamicRewardOf(sender);
            withdrawable = _benefit;
        } else if (sender==_zhang.account) {
            _benefit = _zhang.rewards;
            withdrawable = _benefit;
        } else if (sender==_lee.account) {
            _benefit = _lee.rewards;
            withdrawable = _benefit;
        } else {
            Node storage node = _nodes[sender];
            if (node.balance>0) {
                (bool overFlowed,uint staticRewards,uint dynamicRewards,uint rewards) = allRewardOf(sender);
                require(!overFlowed, "# Overflowed");
                _benefit = staticRewards + dynamicRewards;
                if (node.layer<5) {
                    withdrawable = _benefit * 850 / 1000 + rewards;
                } else if (node.layer>998) {
                    withdrawable = (_benefit + rewards) * 850 / 1000;
                } else {
                    withdrawable = _benefit * 850 / 1000;
                }
            }
        }
        return withdrawable;
    }
    
    function circulatingTLB() public view returns(uint) {
        return totalSupply() - totalBurnt;
    }


    function _branchMembers(address account,uint count) internal view returns(address[20] memory) {
        address[20] memory _children;
        Node storage node = _nodes[account];
        Node storage child = node;
        uint k = 0;
        _children[k++]= account;
        while(child.branches.length>0 && k<count) {
            address addr = child.branches[0].child;
            _children[k++]= addr;
            child = _nodes[addr];
        }
        return _children;
    }
    function _staticRewardOf(address addr, uint from,uint to) internal view returns(uint) {
        uint result = 0;
        Node storage node = _nodes[addr];
        uint len = node.logs.length;
        for(uint i=len; i>0; i++) {
            FundLog storage _log1 = node.logs[i-1];
            uint _from = _log1.time;
            uint _to = 0; 
            if (i==len) {
                _to = now;
            } else {
                _to = node.logs[i].time;
            }
            if (from>_to || to<_from) continue;
            if (_from < from) _from = from;
            if (_to > to) _to = to;
            
            uint _diff = _to - _from;
            if (_diff>864000) {
                result = SafeMath.add(result, _log1.balance * _tiers[_log1.tier-1].staticRewards * _diff / 86400000);
            }
            // if lastlog is withdrawal
            if (_log1.change<0) break;
        }
        return result;
    }
    
    function _setInsurance(bool flag) internal returns(bool) {
        _insuranceStatus = flag;
        return _insuranceStatus;
    }
    
    function _isTriggeredInsurance() internal view returns(bool) {
        if (_insuranceStatus) return true;
        uint len = _totalLogs.length;
        if (len>1) {
            // the total amount is less than 1% of past 36hrs's
            uint increament = (_totalLogs[len-1].balance - _totalLogs[len-2].balance) * 1000 / _totalLogs[len-1].balance; 
            return increament<20;
        }
        return false;
    }
    function refererOf(address sender) public view returns(address) {
        return _nodes[sender].referer;
    }
    function isOverflowed(address sender) public view returns(bool) {
        Node storage node = _nodes[sender];
        if (node.isOverflowed) return true;
        bool overflowed = _isTriggeredInsurance();
        if (overflowed) {
            if (node.logs.length>0) {
                /* uint time = _totalLogs[_totalLogs.length-1].time; */
                FundLog storage nodelog = node.logs[node.logs.length-1];
                if (_totalLogs[_totalLogs.length-1].time<nodelog.time && nodelog.change>0) {
                    overflowed = false;
                }
            }
        }
        return overflowed;
    }
    function rewardOf(address sender) public view returns(uint) {
        Node storage node = _nodes[sender];
        uint rewards = node.rewards;
        FundLog[] storage logs = node.logs;
        uint _from = 0;
        uint _fromIndex = 0;
        uint len = logs.length;
        if (len>0) {
            for(uint i=len-1; i>0; i--) {
                FundLog storage _log1 = logs[i-1];
                if (_log1.change<0) {
                    _from = _log1.time;
                    _fromIndex = i;
                    break;
                }
            }
        }
            
        if (node.layer>998 && node.layer<1002) {
            for(uint i=0;i<_luckyLogs.length;i++) {
                FundLog storage _log1 = _luckyLogs[i];
                if (_log1.time>_from) {
                    rewards += _log1.balance / 2998;
                }
            }
        }
        for(uint i=0;i<insurLogs.length;i++) {
            Insurance storage log = insurLogs[i];
            if (log.time>_from) {
                for(uint k=_fromIndex; i<len; i++) {
                    FundLog storage _log1 = logs[i-1];
                    if (_log1.change>0 && _log1.time<log.time && _log1.time>log.time-7200) {
                        rewards += log.amount / log.count;        
                        break;
                    }
                }
            }
        }
        return rewards;
    }
    function staticRewardOf(address sender) public view returns(uint) {
        return _staticRewardOf(sender,0,0);
    }
    function dynamicRewardOf(address sender) public view returns(uint) {
        if (firstAddress==address(0)) return 0;
        uint dynamicRewards = 0;
        if (sender==_zhang.account) {
            return _zhang.rewards;
        } else if (sender==_lee.account) {
            return _lee.rewards;
        } else if (sender==_admin.account) {
            uint len = _admin.logs.length;
            // calculate PNode static rewards;
            for(uint i=(len==0?len-1:1); i>0; i--) {
                uint _from = 0;
                uint _to = 0;
                uint _sprigs = 0;
                int _change = 0;
                if (len==0) {
                    _from = 0;
                    _to = now;
                    _sprigs = _tiers[3].sprigs;
                    _change = 0;
                } else {
                    FundLog storage _log1 = _admin.logs[i-1];
                    _from = _log1.time;
                    _to = i==len ? now : _admin.logs[i].time;
                    _sprigs = _tiers[_log1.tier-1].sprigs;
                    _change = _log1.change;
                    
                }
                
                uint childStatic = _staticRewardOf(firstAddress, _from, _to);
                dynamicRewards += childStatic * sprigs[0][2] / 1000;
                if (_change<0) break;
            }
            Node storage node = _nodes[firstAddress];
            for (uint b=0; b<node.branches.length; b++) {
                dynamicRewards += _dynamicRewardOf(node.branches[b].child, sender, 4, 1);
            }
        } else if (sender==firstAddress) {
            Node storage node = _nodes[sender];
            for (uint b=0; b<node.branches.length; b++) {
                dynamicRewards += _dynamicRewardOf(node.branches[b].child, sender, 0, 0);
            }
        } else {
            Node storage node = _nodes[sender];
            uint countBranch = node.referalCount / 3;
            if (countBranch>0) {
                for (uint b=0; b<countBranch; b++) {
                    dynamicRewards += _dynamicRewardOf(node.branches[b].child, sender, 0, 0);
                }
            }
        }
        
        return dynamicRewards;
    }
    function _dynamicRewardOf(address firstChild, address sender, uint8 tier,uint tierStart) public view returns(uint) {
        address[20] memory _children = _branchMembers(firstChild,20-tierStart);
        uint dynamicRewards = 0;
        
        FundLog[] storage logs;
        if (sender==_admin.account) {
            logs = _admin.logs;
        } else {
            logs = _nodes[sender].logs;
        }
        uint len = logs.length;
        for(uint i=(len==0?len-1:1); i>0; i--) {
            uint _from = 0;
            uint _to = 0;
            uint _sprigs = 0;
            int _change = 0;
            if (len==0) {
                _from = 0;
                _to = now;
                _sprigs = _tiers[tier-1].sprigs;
                _change = 0;
            } else {
                FundLog storage _log1 = logs[i-1];
                _from = _log1.time;
                _to = i==len ? now : logs[i].time;
                _sprigs = _tiers[_log1.tier-1].sprigs;
                _change = _log1.change;
            }
            
            for(uint j=tierStart; j<=_sprigs; j++) {
                for(uint k=sprigs[j][0]; k<=sprigs[j][1]; k++) {
                    if (_children[k-1]!=address(0)) {
                        uint rate = sprigs[j][2];
                        uint childStatic = _staticRewardOf(_children[k-1], _from, _to);
                        dynamicRewards += childStatic * rate / 1000;    
                    }
                }
            }
            // if lastlog is withdrawal
            if (_change<0) break;
        }
        return dynamicRewards;
    }
    function allRewardOf(address sender) public view returns(bool,uint,uint,uint) {
        Node storage node = _nodes[sender];
        if (node.tier>0 && node.balance>0) {
            bool overflowed = isOverflowed(sender);
            uint staticRewards = staticRewardOf(sender);
            uint dynamicRewards = dynamicRewardOf(sender);
            uint rewards = rewardOf(sender);
            if (!overflowed) {
                overflowed = (node.balance + staticRewards + dynamicRewards + rewards) > node.balance * _tiers[node.tier-1].limit / 1000;
            }
            return (overflowed,staticRewards,dynamicRewards,rewards);    
        }
        return (false,0,0,0);
    }
    
    function nodeinfo(address sender) public view returns(uint,uint,uint,uint,uint) {
        uint totalWithdrawal = 0;
        uint limit = 0;
        uint children = 0;
        uint totalScore = 0;
        uint totalDeposit = 0;
        // ChildInfo[] memory childrenInfo = new ChildInfo[](10);
        if (sender==_admin.account) {
            totalWithdrawal = _admin.totalRewards;
        } else if (sender==_zhang.account) {
            totalWithdrawal = _admin.totalRewards;
        } else if (sender==_lee.account) {
            totalWithdrawal = _admin.totalRewards;
        } else {
            Node storage node = _nodes[sender];
            totalWithdrawal = node.totalWithdrawal;
            totalDeposit = node.totalDeposit;
            limit = node.limit;
            uint brachCount = node.referalCount / 3;
            for(uint i=0; i<brachCount; i++) {
                Node storage child = _nodes[node.branches[i].child];
                totalScore += child.totalDeposit;
                children++;
                while(child.branches.length>0) {
                    address addr = child.branches[0].child;
                    child = _nodes[addr];
                    totalScore += child.totalDeposit;
                    children++;
                }
            }
        }
        return (totalWithdrawal,limit,children,totalScore,totalDeposit);
        
    }
    function noderewards(address sender) public view returns(uint) {
        return _withdrawable(sender, now);
    }
    
    function minerPrice(uint8 tier) public view returns(uint) {
        if (tier>0 && tier<4) {
            return _minerTiers[tier][0] + _minerTiers[tier][0] * currentLayer / 1000; 
        }
        return 0;
    }
    function minerTierInfo(uint amountUsdt) internal view returns(uint8,uint) {
        for(uint i=0; i<_minerTiers.length; i++) {
            uint minerPrice = _minerTiers[i][0];
            uint price = minerPrice + minerPrice * currentLayer / 1000;
            if (price==amountUsdt) {
                if (currentLayer>100) return (uint8(_minerTiers[i][1]),_minerTiers[i][3]);
                return (uint8(_minerTiers[i][1]),_minerTiers[i][2]);
            }
        }
        return (0, 0);
    }
    function minerCount() public view returns(uint) {
        return minePool.minerCount;
    }
    function totalMinePower() public view returns(uint) {
        return minePool.totalPower;
    }
    
    function referedMinersOf(address account) public view returns(uint) {
        return _referedMiners[account].length;
    }
    
    function totalReferedMinerPowerOf(address account) public view returns(uint) {
        uint _total = 0;
        for (uint i=0; i<_referedMiners[account].length; i++) {
            Miner storage miner = _miners[_referedMiners[account][i]];
            _total += miner.tier;
        }
        return _total;
    }
    
    function pendingTLB(address account) public view returns(uint) {
        Miner storage miner= _miners[account];
        if (miner.lastBlock!=0) {
            if (miner.mineType==MineType.Flexible) {
                uint diff = block.number - miner.lastBlock;
                if (diff>9600) diff = 9600;
                return diff * 48000 * 10 ** uint(decimals()) * miner.tier / (28800 * minePool.totalPower);
            } else {
                return (block.number - miner.lastBlock) * 48000 * 10 ** uint(decimals()) * miner.tier / (28800 * minePool.totalPower);
            }
        }
        return 0;
    }
    
    function withdrawTLBFromPool() public {
        address sender = _msgSender();
        require(sender!=address(0), "# Invalid_sender");
        Miner storage miner= _miners[sender];
        uint withdrawal = pendingTLB(sender);
        require(withdrawal>0, "# Invalid_sender");
        require(minePool.minedTotal + withdrawal<= totalMineable, "# overflow_total_mine");
        miner.lastBlock = miner.mineType==MineType.Flexible ? 0 : block.number;
        minePool.minedTotal += withdrawal;
        _mint(sender, withdrawal);
    }
    
    function _addMiner(address sender, address referalLink, uint amountUsdt, MineType mineType, uint8 tier, uint referalRewards, uint time) internal {
        Miner storage miner= _miners[sender];
        
        if (miner.referer!=address(0)) {
            if (miner.tier!=0) {
                require(miner.referer == referalLink, "Invalid_ReferalLink");
            }
            _referedMiners[referalLink].push(sender);
            miner.referer = referalLink;
        }
        if (miner.tier==0) {
            miner.mineType = mineType;
            miner.tier = tier;
            miner.lastBlock = 0;
            minePool.minerCount++;
            _minerlist.push(sender);
        } else {
            miner.tier += tier;
            
        }
        minePool.totalPower += tier;
        
        redeemAmount += referalRewards * 10 / 100;
        _admin.rewards += amountUsdt * 20 / 1000; // 2%
        _zhang.rewards += amountUsdt * 15 / 1000; // 1.5%
        _lee.rewards += amountUsdt * 15 / 1000; // 1.5%
    }
     
    
    function deposit(address referalLink, uint amount) public {
        address sender = _msgSender();
        require(sender!=address(0), "# Invalid_sender");
        uint32 userCount = totalUsers;
        require(userCount < maxUsers, "# full_users");
        
        if (userCount==0) {
            require(referalLink==admin(), "# Need_Admin_refereal_link");
        } else if (userCount<10){
            require(referalLink==firstAddress, "# NeedpNode_refereal_linkAddress");
        } else {
            require(isValidReferer(sender,referalLink), "# invalid_referal_link");
        }
        uint lastDeposit = _nodes[sender].lastAmount;
        if (lastDeposit==0) {
            require(amount - lastDeposit >= 100 * _usdt, "# Too_Low_Invest");    
        } else {
            require(amount >= 200 * _usdt, "# Too_Low_Invest");
        }
        
        uint _needTps = _neededTPSForDeposit(amount) * uint(10) ** decimals();
        
        require(balanceOf(sender) >= _needTps, "# Need_10%_TPS");
        
        TransferHelper.safeTransferFrom(USDTToken, sender, address(this), amount);
        _burn(sender, _needTps);
        totalBurnt += _needTps;
        updateNodeInDeposit(sender, referalLink, amount, now);
        _processSellOrder();
    }
    function withdraw() public {
        address sender = _msgSender();
        require(sender!=address(0), "# Invalid_sender");
        uint withdrawal = _withdrawal(sender, now);
        
        if (withdrawal>0) {
            uint _needTps = _neededTPSForWithdraw(sender);
            TransferHelper.safeTransfer(USDTToken, sender, withdrawal);
            if (_needTps>0) {
                _burn(sender, _needTps);
                totalBurnt += _needTps;
            }
            
            if (sender==_zhang.account) {
                _zhang.totalRewards += withdrawal;
                
            } else if (sender==_lee.account) {
                _lee.totalRewards += withdrawal;
            } else if (sender==_admin.account) {
                _admin.totalRewards += withdrawal;
            } else {
                _nodes[sender].totalWithdrawal += withdrawal;
            }
        }
        _processSellOrder();
    }
    function minerInfo(address miner) public view returns(uint,MineType,bool) {
        bool status = false;
        Miner storage miner= _miners[miner];
        if (miner.lastBlock>0) {
            if (miner.mineType==MineType.Flexible) {
                status = (block.number - miner.lastBlock)<9600;
            } else {
                status = true;
            }
        }
        return (miner.tier,miner.mineType,status);
    }
    function startMine() public {
        address sender = _msgSender();
        require(sender!=address(0), "# Invalid_sender");
        Miner storage miner= _miners[sender];
        require(miner.referer!=address(0), "# Invalid_miner");
        require(miner.lastBlock==0, "# Already_started");
        miner.lastBlock = block.number;
    }
    function setMineType(MineType mineType) public {
        address sender = _msgSender();
        require(sender!=address(0), "# Invalid_sender");
        Miner storage miner= _miners[sender];
        require(miner.referer!=address(0), "# Invalid_miner");
        miner.mineType = mineType;
    }
    
    function buyMiner(address referalLink, uint amountUsdt, MineType mineType) public returns(uint) {
        address sender = _msgSender();
        require(sender!=address(0), "# Invalid_sender");
        (uint8 tier, uint referalRewardRate) = minerTierInfo(amountUsdt);
        require(tier>0, "# Invalid_amount");
        uint referalRewards = amountUsdt * referalRewardRate / 1000;
        TransferHelper.safeTransferFrom(USDTToken, sender, address(this), amountUsdt - referalRewards + referalRewards * 10 / 100);
        TransferHelper.safeTransferFrom(USDTToken, sender, referalLink, referalRewards * 90 / 100);
        _addMiner(sender, referalLink, amountUsdt, mineType, tier, referalRewards, now);
    }
    function minerList() public view returns(uint, MinerInfo[] memory) {
        uint count = _minerlist.length;
        MinerInfo[] memory miners = new MinerInfo[](count);
        for(uint i=0; i<count; i++) {
            miners[i].account = _minerlist[i];
            miners[i].tier = _miners[_minerlist[i]].tier;
        }
        return (minePool.totalPower,miners);
    }
    
    function buy(uint amountUsdt) public {
        address sender = _msgSender();
        require(sender!=address(0), "# Invalid_sender");
        uint _tpsInit = amountUsdt / price * uint(10) ** decimals();
        uint _tps = _tpsInit;
        TransferHelper.safeTransferFrom(USDTToken, sender, address(this), amountUsdt);
        
        uint countRemove = 0;
        for(uint i=0; i<_sellBook.length; i++) {
            Order storage order = _sellBook[i];
            if (order.balance>=_tps) {
                TransferHelper.safeApprove(USDTToken, order.account, _tps * price);
                TransferHelper.safeTransfer(USDTToken, order.account, _tps * price);
                _txBook.push(OrderTx({txid:_txBook.length+1,txtype:0,quantity:_tps,time:now}));
                order.balance -= _tps;
                _tps = 0;
                if (order.balance==0) countRemove++;
                break;
            } else {
                TransferHelper.safeApprove(USDTToken, order.account, order.balance * price);
                TransferHelper.safeTransfer(USDTToken, order.account, order.balance * price);
                _txBook.push(OrderTx({txid:_txBook.length+1,txtype:0,quantity:order.balance,time:now}));
                _tps -= order.balance;
                order.balance = 0;
                countRemove++;
            }
        }
        if (countRemove>0) {
            for(uint i=countRemove;i<_sellBook.length;i++) {
                _sellBook[i-countRemove].account = _sellBook[i].account;
                _sellBook[i-countRemove].initial = _sellBook[i].initial;
                _sellBook[i-countRemove].balance = _sellBook[i].balance;
            }
            for(uint i=0;i<countRemove;i++) {
                _sellBook.pop();
            }
        }
        if (_tps>0) {
            uint balance = _tps*price;
            _buyBook.push(Order({
                time:now,
                account:sender,
                initial:amountUsdt,
                balance:balance
            }));
            emit BuyOrderAdded(sender, balance);
        }
        uint _tpsBuy = _tpsInit - _tps;
        if (_tpsBuy>0) {
            _transfer(address(this), sender, _tpsBuy);
        }
        _processSellOrder();
    }
    function cancelBuyOrder() public {
        address sender = _msgSender();
        require(sender!=address(0), "# Invalid_sender");
        uint count = 0;
        uint balance = 0;
        for(uint i=0;i<_buyBook.length;i++) {
            Order storage order = _buyBook[i];
            if (order.account==sender) {
                balance += order.balance;
                count++;
                continue;
            }
            if (count>0) {
                _buyBook[i-count].account = _buyBook[i].account;
                _buyBook[i-count].initial = _buyBook[i].initial;
                _buyBook[i-count].balance = _buyBook[i].balance;    
            }
        }
        if (count>0) {
            for(uint i=0; i<count; i++) _buyBook.pop();
            TransferHelper.safeApprove(USDTToken, sender, balance);
            TransferHelper.safeTransfer(USDTToken, sender, balance);
            emit BuyOrderCancelled(sender, balance);
        }
        _processSellOrder();
    }
    function sell(uint amountTps) public {
        address sender = _msgSender();
        require(sender!=address(0), "# Invalid_sender");
        
        uint _usdtInit = amountTps * price;
        uint _usdtBalance = _usdtInit;
        _transfer(sender, address(0), amountTps);
        
        uint countRemove = 0;
        for(uint i=0; i<_buyBook.length; i++) {
            Order storage order = _buyBook[i];
            if (order.balance>=_usdtBalance) {
                uint _tps = _usdtBalance / price;
                _transfer(address(this), order.account, _tps);
                _txBook.push(OrderTx({txid:_txBook.length+1,txtype:1,quantity:_tps,time:now}));
                order.balance -= _usdtBalance;
                _usdtBalance = 0;
                if (order.balance==0) countRemove++;
                break;
            } else {
                uint _tps = order.balance / price;
                _transfer(address(this), order.account, _tps);
                _txBook.push(OrderTx({txid:_txBook.length+1,txtype:1,quantity:_tps,time:now}));
                _usdtBalance -= order.balance;
                order.balance = 0;
                countRemove++;
            }
        }
        if (countRemove>0) {
            for(uint i=countRemove;i<_buyBook.length;i++) {
                _buyBook[i-countRemove].account = _buyBook[i].account;
                _buyBook[i-countRemove].initial = _buyBook[i].initial;
                _buyBook[i-countRemove].balance = _buyBook[i].balance;
            }
            for(uint i=0;i<countRemove;i++) {
                _buyBook.pop();
            }
        }
        if (_usdtBalance>0) {
            uint balance = _usdtBalance/price;
            _sellBook.push(Order({
                time: now,
                account:sender,
                initial:amountTps,
                balance:balance
            }));
            emit SellOrderAdded(sender, balance);
        }
        if (_usdtInit - _usdtBalance>0) {
            uint _sold = (_usdtInit - _usdtBalance) / price;
            TransferHelper.safeApprove(USDTToken, sender, _sold);
            TransferHelper.safeTransfer(USDTToken, sender, _sold);
        }
        _processSellOrder();
    }
    function cancelSellOrder() public {
        address sender = _msgSender();
        require(sender!=address(0), "# Invalid_sender");
        uint count = 0;
        uint balance = 0;
        for(uint i=0;i<_sellBook.length;i++) {
            Order storage order = _sellBook[i];
            if (order.account==sender) {
                balance += order.balance;
                count++;
                continue;
            }
            if (count>0) {
                _sellBook[i-count].time = _sellBook[i].time;
                _sellBook[i-count].account = _sellBook[i].account;
                _sellBook[i-count].initial = _sellBook[i].initial;
                _sellBook[i-count].balance = _sellBook[i].balance;
            }
        }
        if (count>0) {
            for(uint i=0; i<count; i++) _sellBook.pop();
            _transfer(address(this), sender, balance);
            emit SellOrderCancelled(sender, balance);
        }
        _processSellOrder();
    }
    function orderHistory() public view returns(OrderTx[] memory) {
        uint count = _txBook.length>10 ? 10 : _txBook.length;
        OrderTx[] memory logs = new OrderTx[](count);
        for(uint i=0; i<count; i++) {
            OrderTx storage order = _txBook[_txBook.length-count];
            logs[i].txid = order.txid;
            logs[i].txtype = order.txtype;
            logs[i].quantity = order.quantity;
            logs[i].time = order.time;
        }
        return logs;
    }
    function _processSellOrder() internal {
        uint count = 0;
        uint sumTps = 0;
        uint _redeemAmount = redeemAmount * 5 / 100;
        for(uint i=0;i<_sellBook.length;i++) {
            Order storage order = _sellBook[i];
            if (now-order.time>86400) {
                uint amount = order.balance * price;
                if (_redeemAmount >= amount) {
                    count++;
                    _redeemAmount -= amount;
                    redeemAmount -= amount;
                    sumTps += order.balance;
                    TransferHelper.safeApprove(USDTToken, order.account, amount);
                    TransferHelper.safeTransfer(USDTToken, order.account, amount);
                    if (count==2) break;
                } else {
                    break;
                }
            }
        }
        if (sumTps>0) _transfer(address(this), redeemAddress, sumTps);
    }
}

