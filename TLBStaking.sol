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
    //会员类型
    enum NodeType{ PNode, Shareholder, Guest }
    //矿工种类 灵活挖矿 or 固定挖矿
    enum MineType{ Flexible, Fixed }
    
    //会员等级
    struct Tier {
        uint8 index;
        uint min; //最小存款金额
        uint8 staticRewards;//静态收益
        uint8 sprigs;//动态收益矩阵
        uint limit;//综合收益
    }

    //存款记录表
    struct FundLog {
        uint time;
        uint balance;
        uint tier;
    }
    
    //分支
    struct Branch {
        address child;
        uint time; // After filling 3 referees, set it to block time
    }

    //管理员
    struct Admin {
        address account;
        uint rewards;
        uint totalRewards;
        uint lastWithdrawTime;
    }
    
    //节点数据结构
    struct Node {
        uint32 position; // location in prism  数组中的位置
        uint16 layer; // location in prism   棱形中的层数
        NodeType role;//角色
        uint8 tier;//会员等级
        uint totalDeposit;//总存款
        uint totalWithdrawal; //总提现金额
        bool isOverflowed; // calculate statically + dynamically(for 1999, 2000, 2001 layer) 是否爆仓，爆仓以后可以继续看到收益增长，但无法提现，必须下一次充值以后提现
        uint lastAmount;//上一次存款金额
        
        uint lastTime;//上次 存款/提现时间
        // uint lastWithdrawTime; // 上次提现金额 
        uint staticRewards;
        uint dynamicRewards;
        
        uint limit;//综合收益
        uint balance;//剩余本金
        uint rewards; // for shareholder 4% or position rewards, calculate statically and dynamically(999~1001) 股东收益 或者 位置奖金 

        
        //推荐人
        address referer;
        //父节点
        address parent;
        
        // for MLM Tree 直接推荐了多少个人
        uint16 referalCount;
        //分支数，子节点个数
        Branch[] branches; // first child address (may be not his referee) in every branch
        
        // will save all history to calculate dynamicRewards dynamically  用户出入金记录
        // FundLog[] logs;
        
    }
    
    //矿工
    struct Miner {
        MineType mineType;
        address referer;//推荐人
        uint tier;//算力
        uint lastBlock;//上一次激活挖矿时间
        uint rewards;//可以提现的TLB数量
    }
    //矿工信息
    struct MinerInfo {
        address account; //地址
        uint tier;//算力
    }
    //矿池统计
    struct MinePool {
        uint totalPower; //总算力
        uint minerCount; //矿工个数
        uint minedTotal; //已经挖出多少矿
    }
    //订单表
    struct Order {
        uint time;
        address account;
        uint initial;
        uint balance;
    }
    //交易记录表
    struct OrderTx {
        uint txid;
        uint8 txtype;
        uint quantity;
        uint time;
    }
    struct ChildInfoReturn {
        uint count;
        uint funds;
        uint rewards;
    }
    //管理员
    Admin _admin;
    //张总
    Admin _zhang;
    //李总
    Admin _lee;

    //累计销毁
    uint public totalBurnt = 0;
    //火币链上usdt代币地址
    address USDTToken = 0xE5f2A565Ee0Aa9836B4c80a07C8b32aAd7978e22;
    //代币精度
    uint8 USDTPrecision = 2;
    uint _usdt = uint(10) ** USDTPrecision;

    /* address USDTToken = 0x5e17b14ADd6c386305A32928F985b29bbA34Eff5; //0xFedfF21d4EBDD77E29EA7892c95FCB70bd27Fd28;
    uint8 USDTPrecision = 6; */
    
    // heco mainnet 
    // address USDTToken = 0xa71EdC38d189767582C38A3145b5873052c3e47a;
    // uint8 USDTPrecision = 18;
        
    uint _tpsIncrement = _usdt / 100; //TLB涨幅，每一层
    uint public price = _usdt / 10;// TLB 初始价格
    uint32 public maxUsers = 500500+499500; //最大用户数
    uint32 public totalUsers = 0;//目前用户数
    uint16 public currentLayer = 0;//当前层级
    uint16 _positionInLayer = 0;//当前位置在 某一层中的位置
    
    
    uint public totalMineable = 28032000; //总计可以挖出来的矿
    uint public totalDeposit = 0;//系统总计存款
    
    //保险状态
    uint public insuranceCounterTime = now;
    uint _insuranceTime = 0;
    uint _insuranceDeposit = 0;
    address[36] _insuranceMembers;
    uint _insuranceMemberCount;
    
    
    // 奖励最后入金的36个人:
    // 最后一个人 奖励 20%
    // 剩余35人平均分配 80%
    /*
    struct Insurance {
        uint time;
        uint amount;
        uint count;
    }
    Insurance[] insurLogs;
    */
    
    //动态收益列表
    uint8[][] sprigs = [
        [1, 1, 200], // 吃 第1层 静态收益的20%
        [2, 2, 150],// 吃 第2层 静态收益的15%
        [3, 7, 100],// 吃 第3-7层 静态收益的10%
        [8, 15, 50],// 吃 第8-15层 静态收益的5%
        [16, 20, 20]// 吃 第15-20层 静态收益的2%
    ];
    
    //第一个地址
    address public firstAddress; // by admin
    
    mapping(uint32 => address) private _prism; 
    mapping(address => Node) private _nodes;
    
    Tier[] _tiers;
    
    address public redeemAddress; // 1.5% redeem
    uint public redeemAmount; // 1.5% redeem
    uint _controlAmount; // 1.5% redeem
    
    FundLog[] _inLogs; // all deposit logs; 所有入金账本
    FundLog[] _totalLogs;
    FundLog[] _luckyLogs;  // for 999 ~ 1001 layers; 位置奖金账本

    //矿工初始价格，和推广收益表
    uint[][] _minerTiers = [
        [15000 * 10 ** uint(USDTPrecision), 100, 100, 30], //15000U,100T,10%,30%
        [7500 * 10 ** uint(USDTPrecision), 50, 50, 20], 
        [3500 * 10 ** uint(USDTPrecision), 25, 25, 10], 
        [100 * 10 ** uint(USDTPrecision), 5, 10, 5]
    ];

    //矿工列表
    address[] _minerlist;
    mapping(address=>Miner) _miners;
    mapping(address=>address[]) _referedMiners;
    
    MinePool minePool;
    Order[] _buyBook;
    Order[] _sellBook;
    OrderTx[] _txBook;
    
    
    
    //构造方法， 合约创建时候执行
    constructor () public {
        uint _initialSupply  = maxSupply() * 20 / 100;
        _mint(msg.sender, _initialSupply);
        
        //初始化会员等级
        _tiers.push(Tier({
            index: 1,
            min: 200,
            staticRewards: 16,  // 0.1%
            sprigs: 2,
            limit: 2200        // 0.1% 综合收益倍数
        }));
        _tiers.push(Tier({
            index: 2,
            staticRewards: 14,
            min: 1001,
            sprigs: 3,
            limit: 2100        // 0.1%
        }));
        _tiers.push(Tier({
            index: 3,
            staticRewards: 12,
            min: 2001,
            sprigs: 4,
            limit: 2000        // 0.1%
        }));
        _tiers.push(Tier({
            index: 4,
            staticRewards: 10,
            min: 5001,
            sprigs: 5,
            limit: 1900        // 0.1%
        }));
    }

    //设置管理员，张总，李总 钱包地址。需要设置管理员地址，张总地址，李总地址。注意（张总，李总）作为股东身份参与，请另外使用地址
    function setAdmin(address admin,address lee,address zhang,address redeem) public {
        _admin.account = admin;
        _lee.account = lee;
        _zhang.account = zhang;
        redeemAddress = redeem;
    }
    /**
     * @dev Returns Admin address. 返回管理员地址
     */
    function admin() public view returns(address) {
        return _admin.account;
    }
    
    /**
     * @dev Returns zhang address. 返回张总地址
     */
    function zhang() public view returns(address) {
        return _zhang.account;
    }
    /**
     * @dev Returns Admin address. 返回李总地址
     */
    function lee() public view returns(address) {
        return _lee.account;
    }
    
    /**
     * internal
     * @dev Returns tier index corresponding to deposit amount. 根据入金数额获取当前会员等级
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
     * @dev indicates the referal link is valid or not. 判断推荐连接是否正确
     */
    function isValidReferer(address sender, address referer) internal view returns(bool) {
        if (_nodes[referer].lastAmount == 0) return false;
        if (_nodes[sender].lastAmount == 0) return true;
        return _nodes[sender].referer==referer;
    }
    
    /**
     * internal
     * @dev indicates the node is exist or not. 判断用户是否存在
     */
    function existNode(address sender) internal view returns(bool) {
        return _nodes[sender].lastAmount > 0;
    }
    
    /**
     * @dev Return required number of TPS to member. 计算入金时候需要的TLB数量
     */
    function _neededTPSForDeposit(uint amount) public view returns(uint256) {
        return amount /  10 / price; // 10% TPS of amount
    }
    /**
     * @dev Return required number of TPS to member. 计算出金的时候TLB数量，前1000层 5个，1001层开始2个
     */
    function _neededTPSForWithdraw(address account) public view returns(uint256) {
        if (account==_zhang.account || account==_lee.account || account==_admin.account) return 0;
        return _nodes[account].layer<1001 ? 5 : 2;
    }
    /**
     * internal
     * @dev Logically add users to prism.
     * At this time, if the current layer is filled by the user, the number of layers and the price of TPS tokens will change.
     * 新增用户时候，把用户加入到棱形位置中 返回总用户数
     */
    function addUserToPrism() internal returns(uint32) {
        //当前层 可以允许的最大用户数
        uint32 maxUsersInLayer = currentLayer < 1001 ? currentLayer : 2000 - currentLayer;
        //当前层会员填满，需要新加一层，TLB涨价0.01
        if (maxUsersInLayer == _positionInLayer) {
            currentLayer++;
            price = SafeMath.add(price,_tpsIncrement);
            _positionInLayer = 1;
        }
        //不需要新增层
         else {
            _positionInLayer++;
        }
        //总用户增加1
        totalUsers++;
        return totalUsers;
    }
    
    
    
    /**
     * internal
     * @dev returns last node in branch. 返回分支上的最长路径节点 递归 recursive
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
     * @dev returns shareholder of linked chain of sender. 向上查找股东节点
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
     * @dev Add or update a node when a user is deposited into the pool. 当用户存钱的时候，更新树形结构
     */
    function updateNodeInDeposit(address sender,address referalLink, uint amount, uint time) internal {
        Node storage node = _nodes[sender];
        Node storage refererNode = _nodes[referalLink];
        //新用户第一次入金，改变树形结构
        if (node.lastTime==0) {
            uint32 position = addUserToPrism();
            address parent;
            //共生节点
            if (totalUsers==1) {
                node.role = NodeType.PNode;
                firstAddress = sender;
                parent = referalLink;
            } else if (currentLayer<5) { //股东节点
                parent = referalLink;
                node.role = NodeType.Shareholder;
                _nodes[parent].branches.push(Branch(sender,time));
            } else { //其他用户
                node.role = NodeType.Guest;
                uint16 countBranch = refererNode.referalCount / 3;
                uint16 remainInBranch = refererNode.referalCount % 3;
                //如果之前的路径上 推荐满了3个用户，则新开分支
                if (remainInBranch==0) {
                    parent = referalLink;
                    if (countBranch>0) {
                        _nodes[parent].branches[countBranch-1].time = now;
                    }
                    _nodes[parent].branches.push(Branch(sender,0));
                } else {
                    //根据推荐人的地址 查找当前最长路径, 作为最后一个分支的新节点附加
                    parent = getLastInBranch(refererNode.branches[countBranch].child);
                }
            }
            //推荐人的推荐数量+1
            refererNode.referalCount++;
            node.referer = referalLink;
            node.position = position;
            node.layer = currentLayer;
            node.balance = amount;
            
            node.isOverflowed = false;
            node.rewards = 0; // for shareholder
            node.parent = parent;
            node.referalCount = 0;
            if (position > 502503) { // save prism position from 1002 layer
                _prism[position] = sender;
            }
        } else { //老用户入金，不改变结构，直接改变本金
            if (node.isOverflowed) {
                node.staticRewards = 0;//静态设置为0
                node.dynamicRewards = 0;//动态设置为0
            } else {
                
                (bool overflowed,,,,,) = withdrawable(sender);
                if (overflowed) {
                    node.staticRewards = 0;
                    node.dynamicRewards = 0;
                } else {
                    node.staticRewards = _staticRewardOf(node);
                    if (node.staticRewards > 0) {
                        _updateDynamicRewardsAllParentNode(node);
                        
                    }    
                }
            }
            node.balance += amount;
        }
        //更新最后一次存款金额    
        node.lastAmount = amount;
        //更新最后一次存款时间
        node.lastTime = time;
        node.totalDeposit += amount;
        totalDeposit += amount;
        _insuranceDeposit += amount;
        //重新计算会员等级
        uint8 tier = (uint8)(getTier(node.balance));
        //根据新的会员等级，计算综合收益
        node.limit = node.balance * _tiers[tier-1].limit / 1000;
        //更新会员等级
        node.tier = tier;
        //更新爆仓状态 (这里可能需要修改，爆仓状态接触后，需要把会员的动态+静态 部分 设计为0， 股东奖励部分 不清零)
        if (node.isOverflowed) node.isOverflowed=false;
        redeemAmount += amount * 18 / 1000; // 1.5% 回购资金
        _controlAmount += amount * 32 / 1000; // 1.5% 护盘资金
        _admin.rewards += amount * 20 / 1000; // 2% 管理员奖金
        _zhang.rewards += amount * 15 / 1000; // 1.5% 张总奖金
        _lee.rewards += amount * 15 / 1000; // 1.5% 李总奖金
        
        if (_insuranceMemberCount==36) {
            for(uint i=1; i<_insuranceMemberCount;i++) {
                _insuranceMembers[i-1] = _insuranceMembers[i-1];
            }
            _insuranceMemberCount = 35;
        }
        _insuranceMembers[_insuranceMemberCount] = sender;
        _insuranceMemberCount++;
        
        
        if (node.role == NodeType.Guest) {
            Node storage shareholderNode;
            if (refererNode.role==NodeType.Shareholder) {
                shareholderNode = refererNode;
            } else {
                //查找该用户的股东
                address shareholder = getShareholderInBranch(referalLink);
                shareholderNode = _nodes[shareholder];
            }
            shareholderNode.rewards += amount * 40 / 1000; // 4%; 股东奖金
        }
        checkInsurance();
    }
    
    // update dynamicRewards of all parents (max 20)
    function _updateDynamicRewardsAllParentNode(Node storage node) internal {
        // Node storage parent;
        uint8 tier;
        uint rewards = 0;
        for(uint i=0; i<20; i++) {
            tier = node.parent==_admin.account ? 4 : _nodes[node.parent].tier;
            if (tier>=1 && i==1) {
                 rewards = node.staticRewards * sprigs[0][2] / 1000;
            } else if (tier>=1 && i==2) {
                 rewards = node.staticRewards * sprigs[1][2] / 1000;
            } else if (tier>=2 && i>=3 && i<=7) {
                 rewards = node.staticRewards * sprigs[2][2] / 1000;
            } else if (tier>=3 && i>=8 && i<=16) {
                 rewards = node.staticRewards * sprigs[3][2] / 1000;
            } else if (tier>=4) {
                 rewards = node.staticRewards * sprigs[4][2] / 1000;
            }
            if (rewards>0) {
                if (node.parent==_admin.account) {
                    _admin.rewards += rewards;
                    break;
                } else {
                    _nodes[node.parent].dynamicRewards += rewards;
                }
            }
        }
    }
    //计算合约中剩余USDT数目
    function totalUsdtBalance() public view returns(uint) {
        return IHRC20(USDTToken).balanceOf(address(this));
    }
    
    
    function _staticRewardOf(Node storage node) internal view returns(uint) {
        if (node.lastTime<_insuranceTime) {
            return node.balance * _tiers[node.tier-1].staticRewards * (now - _insuranceTime) / 86400000;
        } else {
            return node.staticRewards + node.balance * _tiers[node.tier-1].staticRewards * (now - node.lastTime) / 86400000;
        }
    }
    /**
     * internal
     * @dev returns count, total deposit, dynamicRewards
     */
    
    function _childrenInfo(Node storage node, uint deep, uint maxDeep) internal view returns(ChildInfoReturn memory) {
        uint countBranch = node.referalCount / 3;
        uint staticRewards = 0;
        uint funds = 0;
        uint rewards = 0;
        uint count = 0;
        deep++;
        for(uint i = 0; i<countBranch; i++) {
            Node storage _child = _nodes[node.branches[i].child];
            funds += _child.totalDeposit;
            if (!_child.isOverflowed) {
                staticRewards = _staticRewardOf(_child);
                if (node.tier>=1 && deep==0) {
                     rewards += staticRewards * sprigs[0][2] / 1000;
                } else if (node.tier>=1 && deep==1) {
                     rewards += staticRewards * sprigs[1][2] / 1000;
                } else if (node.tier>=2 && deep>=2 && deep<=6) {
                     rewards += staticRewards * sprigs[2][2] / 1000;
                } else if (node.tier>=3 && deep>=7 && deep<=15) {
                     rewards += staticRewards * sprigs[3][2] / 1000;
                } else if (node.tier>=4) {
                     rewards += staticRewards * sprigs[4][2] / 1000;
                }
                if (deep<maxDeep) {
                    ChildInfoReturn memory ci= _childrenInfo(_child, deep, maxDeep);
                    count += ci.count;
                    funds += ci.funds;
                    rewards += ci.rewards;
                }    
            }
        }
        count += countBranch;
        return ChildInfoReturn(count, funds, rewards);
    }

    //计算可提现金额 正确 o
    function withdrawable(address sender) public view returns(bool, uint, uint, uint, uint, uint) { // overflowed, benefit, rewards, withdrawable, children, totalDepositByChildren
        bool overflowed = false;
        uint benefit = 0;
        uint rewards = 0;
        uint withdrawal = 0;
        uint children = 0;
        uint totalDepositByChildren = 0;
        //计算管理员可提现 正确
        if (sender==_admin.account) {
            Node storage node = _nodes[firstAddress];
            uint r1 = _staticRewardOf(node) * sprigs[0][2] / 1000;
            ChildInfoReturn memory ci = _childrenInfo(node, 1, 19);
            withdrawal = _admin.rewards + r1 + ci.rewards;
            
            children = ci.count + 1;
            totalDepositByChildren = ci.funds + 1;
        } else if (sender==_zhang.account) { //计算张总可提现金额 正确
            withdrawal = _zhang.rewards;
        } else if (sender==_lee.account) { //计算李总可提现 正确
            withdrawal = _lee.rewards;
        } else { //计算其他会员可提现 动态+静态+奖金（位置奖金 或者 股东奖励）正确
            Node storage node = _nodes[sender];
            overflowed = node.lastTime > _insuranceTime;
            if (!overflowed && node.balance>0) {
                rewards = node.rewards;
                uint deep = sprigs[_tiers[node.tier-1].sprigs][1];
                uint staticRewards = _staticRewardOf(node);
                ChildInfoReturn memory ci = _childrenInfo(node, 0, deep);
                children = ci.count;
                totalDepositByChildren = ci.funds;
                benefit = staticRewards + ci.rewards;
                
                if (node.layer>998 && node.layer<1002) {
                    for(uint i=0;i<_luckyLogs.length;i++) {
                        FundLog storage _log1 = _luckyLogs[i];
                        if (_log1.time>node.lastTime) { //如果上一次提现时间，在奖金统计时间中。 则将奖励 计算给用户
                            rewards = _log1.balance / 2998;
                        }
                    }
                }
                overflowed = (staticRewards + ci.rewards + rewards) > node.balance * _tiers[node.tier-1].limit / 1000;
                if (overflowed) {
                    if (node.layer<5) {
                        withdrawal = benefit * 850 / 1000 + rewards;
                    } else if (node.layer>998) {
                        withdrawal = (benefit + rewards) * 850 / 1000;
                    } else {
                        withdrawal = benefit * 850 / 1000;
                    }
                }
            }
        }
        return (overflowed, benefit, rewards, withdrawal, children, totalDepositByChildren);
    }
    
    
    // must call this function every 36hrs on server backend
    function checkInsurance() public {
        if (now - insuranceCounterTime >= 129600) {
            if ((_insuranceDeposit * 1000 / totalDeposit) < 20) {
                _insuranceTime = insuranceCounterTime + 129600;
                uint amount = totalUsdtBalance() * 50 / 1000;
                uint p20 = amount * 20 / 100;
                uint p1 = amount * 80 / 3500;
                for(uint i=0; i<_insuranceMemberCount; i++) {
                    Node storage node = _nodes[_insuranceMembers[i]];
                    node.lastTime = _insuranceTime + 1;
                    node.rewards = i==35 ? p20 : p1;
                }
            }
            _insuranceDeposit = 0;    
            _insuranceMemberCount = 0;
        }
    }
    
    //计算 TLB 流动供应量 
    function circulatingTLB() public view returns(uint) {
        return totalSupply() - totalBurnt;
    }

    function nodeinfo(address sender) public view returns(uint,uint,uint,address) {
        uint _dx = 0;
        uint _wx = 0;
        uint limit = 0;
        address referer = address(0);
        if (sender==_admin.account) {
            _wx = _admin.totalRewards;
        } else if (sender==_zhang.account) {
            _wx = _admin.totalRewards;
        } else if (sender==_lee.account) {
            _wx = _admin.totalRewards;
        } else {
            Node storage node = _nodes[sender];
            _wx = node.totalWithdrawal;
            _dx = node.totalDeposit;
            limit = node.limit;
            referer = node.referer;
        }
        return (_dx,_wx,limit, referer);
    }
    
    
    
    //计算 矿机价格每增加一层 认购价格 矿机认购价格在原基础上 增加0.1% 正确
    function minerPrice(uint8 tier) public view returns(uint) {
        if (tier>0 && tier<4) {
            return _minerTiers[tier][0] + _minerTiers[tier][0] * currentLayer / 1000; 
        }
        return 0;
    }

    //根据购买金额，返回，算力和推广收益 正确
    function minerTierInfo(uint amountUsdt) internal view returns(uint8,uint) {
        for(uint i=0; i<_minerTiers.length; i++) {
            uint _mp = _minerTiers[i][0];
            uint _pr = _mp + _mp * currentLayer / 1000;
            if (_pr==amountUsdt) {
                //大于100层，推广收益变化
                if (currentLayer>100) return (uint8(_minerTiers[i][1]),_minerTiers[i][3]);
                //100层以内，推广收益维持原状
                return (uint8(_minerTiers[i][1]),_minerTiers[i][2]);
            }
        }
        return (0, 0);
    }
    //计算 矿工数量 正确
    function minerCount() public view returns(uint) {
        return minePool.minerCount;
    }
    //计算 总算力 正确
    function totalMinePower() public view returns(uint) {
        return minePool.totalPower;
    }
    
    //计算 推广矿工数量 正确
    function referedMinersOf(address account) public view returns(uint) {
        return _referedMiners[account].length;
    }
    
    //计算 推广矿工的总算力 正确
    function totalReferedMinerPowerOf(address account) public view returns(uint) {
        uint _total = 0;
        for (uint i=0; i<_referedMiners[account].length; i++) {
            // Miner storage miner = ;
            _total += _miners[_referedMiners[account][i]].tier;
        }
        return _total;
    }
    
    //计算 待领取的TLB 奖励 正确
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
    
    //触发领取奖励动作 正确
    function withdrawTLBFromPool() public {
        address sender = _msgSender();
        require(sender!=address(0), "# Invalid_sender");
        Miner storage miner= _miners[sender];
        uint withdrawal = pendingTLB(sender);
        require(withdrawal>0, "# Invalid_sender");
        require(minePool.minedTotal + withdrawal<= totalMineable, "# overflow_total_mine");
        //重新设置一下 矿工区块时间
        miner.lastBlock = miner.mineType==MineType.Flexible ? 0 : block.number;
        //统计总共挖出来的 TLB数量
        minePool.minedTotal += withdrawal;
        _mint(sender, withdrawal);
    }
    
    //添加矿工
    function _addMiner(address sender, address referalLink, uint amountUsdt, MineType mineType, uint8 tier, uint referalRewards, uint time) internal {
        Miner storage miner= _miners[sender];
        
        //如果推荐人不为空 （ 网页连接 不包含 推广码）
        if (miner.referer!=address(0)) {
            if (miner.tier!=0) {
                //以前购买过，必须使用推荐人连接购买
                require(miner.referer == referalLink, "Invalid_ReferalLink");
            }
            //记录推荐人
            _referedMiners[referalLink].push(sender);
            miner.referer = referalLink;
        }
        //如果没有购买过
        if (miner.tier==0) {
            miner.mineType = mineType;//挖矿种类
            miner.tier = tier;//算力大小
            miner.lastBlock = 0;//还不开始挖矿
            minePool.minerCount++;//矿工数+1
            _minerlist.push(sender);//矿工对了+1
        } else {
            //矿工后续购买，该矿工算力增加
            miner.tier += tier;
            
        }
        //矿池算力增加
        minePool.totalPower += tier;
        
        //正确  张总，李总，管理员，分红
        redeemAmount += referalRewards * 10 / 100;
        _admin.rewards += amountUsdt * 20 / 1000; // 2%
        _zhang.rewards += amountUsdt * 15 / 1000; // 1.5%
        _lee.rewards += amountUsdt * 15 / 1000; // 1.5%
    }
     
    //入金方法 外部调用 正确
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

    //提现方法 管理员 出金也需要TLB 管理员购买矿机，可以不要钱
    function withdraw() public {
        address sender = _msgSender();
        require(sender!=address(0), "# Invalid_sender");
        //计算当时间，会员可提金额
        (bool overflowed, uint benefit, uint rewards, uint withdrawal,,) = withdrawable(sender);
        require(!overflowed, "# Overflowed");
        //管理员提现，不扣任何手续费，然后系统记录总账 管理员不能作为用户 参与游戏）
        if (sender==_admin.account) {
            _admin.rewards = 0;
            _admin.totalRewards += withdrawal;
            _admin.lastWithdrawTime = now;
        } else if (sender==_zhang.account) { //张总提现，只扣张的奖金部分，然后系统记录总账（注意，张总地址不能作为用户 参与游戏）
            _zhang.rewards = 0;
            _zhang.totalRewards += withdrawal;
            _zhang.lastWithdrawTime = now;
        } else if (sender==_lee.account) { //李总提现，只扣李的奖金部分，然后系统记录总账（注意，李总地址不能作为用户 参与游戏）
            _lee.rewards = 0;
            _lee.totalRewards += withdrawal;
            _lee.lastWithdrawTime = now;
        } else { //会员提现
            Node storage node = _nodes[sender];
            if (node.balance>0) {
                node.totalWithdrawal += withdrawal;
                node.lastTime = now;
                //计算方式 正确
                uint half = (node.layer<5 ? benefit : benefit + rewards ) / 2;
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
                // Symmetrische Positionsbelohnung 对称位置奖金  (动态收益+静态收益)*50%*30%*50%
                if (node.layer<999) {
                    uint pos = benefit * 75 / 1000; 
                    address posAddr = _prism[2000-node.position]; //对称位置 计算错误
                    //该位置没有用户时候，应该记录奖金累计数。 有用户时候，应该将该奖金加到用户rewards
                    if (posAddr!=address(0)) {
                        Node storage posNode = _nodes[sender];    
                        posNode.rewards += pos;
                    }
                    // Belohnung für jede Position 999-1000-1001 (insgesamt 2998 Personen) 999-1000-1001层 2998 个位置 
                    _luckyLogs.push(FundLog({
                        time:now,
                        balance:pos,
                        tier:0
                    }));
                } else { //其他情况，记录回购资金
                    redeemAmount += benefit * 150 / 1000;
                }
            }
        }
        //如果可提金额大于0
        if (withdrawal>0) {
            //计算需要燃烧的TLB数量
            uint _needTps = _neededTPSForWithdraw(sender);
            TransferHelper.safeTransfer(USDTToken, sender, withdrawal);
            if (_needTps>0) {
                //燃烧用户钱包中的TLB
                _burn(sender, _needTps);
                //统计 总计燃烧数额
                totalBurnt += _needTps;
            }
        }
        _processSellOrder();
    }

    //矿工信息， 返回 算力，挖矿方式，是否激活
    function minerInfo(address miner) public view returns(uint,MineType,bool) {
        bool status = false;
        Miner storage _mnr= _miners[miner];
        if (_mnr.lastBlock>0) {
            if (_mnr.mineType==MineType.Flexible) {
                status = (block.number - _mnr.lastBlock)<9600;
            } else {
                status = true;
            }
        }
        return (_mnr.tier,_mnr.mineType,status);
    }
    //开始挖矿，每次提现后必须重新触发 （需要添加判断 没有购买矿机的人 不能触发该操作）
    function startMine() public {
        address sender = _msgSender();
        require(sender!=address(0), "# Invalid_sender");
        Miner storage miner= _miners[sender];
        require(miner.referer!=address(0), "# Invalid_miner");
        require(miner.lastBlock==0, "# Already_started");
        miner.lastBlock = block.number;
    }

    //设置挖矿 方式 （有待讨论）
    function setMineType(MineType mineType) public {
        address sender = _msgSender();
        require(sender!=address(0), "# Invalid_sender");
        Miner storage miner= _miners[sender];
        require(miner.referer!=address(0), "# Invalid_miner");
        miner.mineType = mineType;
    }
    //购买矿机 
    function buyMiner(address referalLink, uint amountUsdt, MineType mineType) public returns(uint) {
        address sender = _msgSender();
        require(sender!=address(0), "# Invalid_sender");
        (uint8 tier, uint referalRewardRate) = minerTierInfo(amountUsdt); //返回 算力，推荐人奖金比率
        require(tier>0, "# Invalid_amount");
        uint referalRewards = amountUsdt * referalRewardRate / 1000;
        TransferHelper.safeTransferFrom(USDTToken, sender, address(this), amountUsdt - referalRewards + referalRewards * 10 / 100);
        TransferHelper.safeTransferFrom(USDTToken, sender, referalLink, referalRewards * 90 / 100); //若没有推荐人，这里金额转给谁？
        _addMiner(sender, referalLink, amountUsdt, mineType, tier, referalRewards, now);
    }
    //查看矿池，总算力，和总人数 正确
    function minerList() public view returns(uint, MinerInfo[] memory) {
        uint count = _minerlist.length;
        MinerInfo[] memory miners = new MinerInfo[](count);
        for(uint i=0; i<count; i++) {
            miners[i].account = _minerlist[i];
            miners[i].tier = _miners[_minerlist[i]].tier;
        }
        return (minePool.totalPower,miners);
    }
    

    //购买TLB 方法正确
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

    //撤销买单，当 卖队列无法满足 买队列时 正确
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

    //卖出 TLB 方法正确
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
    //撤销卖单
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
    //查询订单历史记录
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
    //触发回购操作
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
