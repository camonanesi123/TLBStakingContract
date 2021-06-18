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
        int change;
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
        FundLog[] logs;
        uint totalRewards;
    }
    
    //节点数据结构
    struct Node {
        uint32 position; // location in prism  数组中的位置
        uint16 layer; // location in prism   棱形中的层数
        address referer;//推荐人
        NodeType role;//角色
        uint8 tier;//会员等级
        uint totalDeposit;//总存款
        uint totalWithdrawal;//总提现金额
        bool isOverflowed; // calculate statically + dynamically(for 1999, 2000, 2001 layer) 是否爆仓，爆仓以后可以继续看到收益增长，但无法提现，必须下一次充值以后提现
        uint lastAmount;//上一次存款金额
        uint lastTime;//上次 存款时间
        uint limit;//综合收益
        uint balance;//剩余本金
        uint rewards; // for shareholder 4% or position rewards, calculate statically and dynamically(999~1001) 股东收益 或者 位置奖金 
        // uint staticRewards; // calculate dynamically
        // uint dynamicRewards;; // calculate dynamically
        //父节点
        address parent;
        
        // for MLM Tree 直接推荐了多少个人
        uint16 referalCount;
        //分支数，子节点个数
        Branch[] branches; // first child address (may be not his referee) in every branch
        
        // will save all history to calculate dynamicRewards dynamically  用户出入金记录
        FundLog[] logs;
        
    }
    
    //矿工
    struct Miner {
        MineType mineType;
        address referer;//推荐人
        uint git;//算力
        uint lastBlock;//上一次激活挖矿时间
        uint rewards;//可以提现的TLB数量
    }
    //矿工信息
    struct MinerInfo {
        address account; //地址
        uint tier;//算力
    }
    //子节点信息
    struct ChildInfo {
        address account;
        uint deposit;
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
    bool _insuranceStatus = false; //保险触发条件
    
    uint public totalMineable = 28032000; //总计可以挖出来的矿
    uint public totalDeposit = 0;//系统总计存款
    
    //保险状态
    struct Insurance {
        uint time;
        uint amount;
        uint count;
    }
    Insurance[] insurLogs;
    
    //动态收益列表
    uint8[][] sprigs = [
        [1, 1, 200], //第1层 吃 静态收益的20%
        [2, 2, 150],//第2层 吃 静态收益的15%
        [3, 7, 100],//第3-7层 吃 静态收益的10%
        [8, 15, 50],//第8-15层 吃 静态收益的5%
        [16, 20, 20]//第15-20层 吃 静态收益的2%
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
        if (!existNode(sender)) {
            uint32 position = addUserToPrism();
            address parent;
            //共生节点
            if (totalUsers==1) {
                node.role = NodeType.PNode;
                firstAddress = sender;
                parent = referalLink;
            } 
            //股东节点
            else if (currentLayer<5) {
                parent = referalLink;
                node.role = NodeType.Shareholder;
                _nodes[parent].branches.push(Branch(sender,time));
            } 
            //其他用户
            else {
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
                    //根据推荐人的地址 查找当前最长路径
                    parent = getLastInBranch(referalLink);
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
            // node.staticRewards = 0;
            // node.dynamicRewards = 0;
            node.parent = parent;
            node.referalCount = 0;
            if (position > 502503) { // save prism position from 1002 layer
                _prism[position] = sender;
            }
        } 
        //老用户入金，不改变结构，直接改变本金
        else {
            node.balance += amount;
        }
        node.totalDeposit += amount;
        totalDeposit += amount;
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
        //更新最后一次存款金额    
        node.lastAmount = amount;
        //更新最后一次存款时间
        node.lastTime = time;
        //用户账本长度
        uint lenLogs = node.logs.length;
        if (lenLogs==0) {
            node.logs.push(FundLog({
                time: time, //更新时间
                tier: node.tier,//用户等级
                balance: node.balance,//剩余本金
                change: (int)(amount)//本次入金数额
            }));
        } else {
            //获取上一次账本记录
            FundLog storage plog = node.logs[lenLogs-1];
            //如果上一次记账记录 和 本次操作时间 没有间隔1天，则修改当天记账记录
            if (now - plog.time < 86400 && plog.change>0) {
                plog.balance += amount; //更新会员剩余本金
                plog.tier += node.tier; //更新会员等级（这里为什么使用+号?)
                plog.change += (int)(amount);
                plog.time = now;
            } 
            //如果上次记账，距现在超过1天，那么新增加一个记账记录
            else {
                node.logs.push(FundLog({
                    time: time,
                    tier: node.tier,
                    balance: node.balance,
                    change: (int)(amount)
                }));
            }
        }
        
        // Versicherung Auslösemechanismus Gesamtbetrag alle 36 Stunden.
        //保险池 触发部分
        uint len = _totalLogs.length;
        uint roundedtime = now - (now % 129600);//36小时 3600*36 为了方便 整除 
        if (len==0) {
            _totalLogs.push(FundLog({
                time:roundedtime,
                balance:amount,
                change:0,
                tier:0
            }));
        } else {
            //把当前入金 加到 上一次入金的帐目中
            uint balance = SafeMath.add(_totalLogs[len-1].balance,amount);
            //如果当前入金时间 刚好能整除 roundedtime 不触发保险
            if (_totalLogs[len-1].time==roundedtime) {
                _totalLogs[len-1].balance = balance;
            } 
            //触发保险算法
            else {
                // check insurance 
                uint increament = (_totalLogs[len-1].balance - _totalLogs[len-2].balance) * 1000 / _totalLogs[len-1].balance; 
                //计算增加比值 当前业绩相对于36小时之前的增加比例不足2%
                if (increament<20) {
                    uint logtime = _totalLogs[len-1].time;
                    if (insurLogs.length==0 || logtime>insurLogs[insurLogs.length-1].time) {
                        uint count = 0;
                        len = _inLogs.length;
                        //查找入金账本上，两小时内入金的用户数
                        for(uint i=len-1; i>=0; i++) {
                            uint diff = logtime - _inLogs[len-1].time;
                            if (diff>0 && diff<7200) count++;
                        }
                        //记录保险账本，可分金额，人数，时间
                        insurLogs.push(Insurance({
                            time: logtime,//记账时间
                            amount: totalUsdtBalance() * 50 / 1000,//合约中剩余Usdt数量的5%
                            count:count //人数
                        }));    
                    }
                }
                //再次记录当前状态
                _totalLogs.push(FundLog({
                    time:roundedtime,
                    balance:balance,
                    change:0,
                    tier:0
                }));
            }
        }

        //在入金总表中记录 当前入金
        _inLogs.push(FundLog({
            time: time,
            tier: 0,
            balance: amount,
            change: 0
        }));
    }
    //计算合约中剩余USDT数目
    function totalUsdtBalance() public view returns(uint) {
        return IHRC20(USDTToken).balanceOf(address(this));
    }
    //出金方法
    function _withdrawal(address sender, uint time) internal returns(uint) {
        uint withdrawable = 0;
        //管理员提现，不扣任何手续费，然后系统记录总账 管理员不能作为用户 参与游戏）
        if (sender==_admin.account) {
            withdrawable = _admin.rewards + dynamicRewardOf(sender);
            _admin.rewards = 0;
            _admin.logs.push(FundLog({
                time: time,
                tier: 4,
                balance: 0,
                change: -(int)(withdrawable)
            }));
        } 
        //张总提现，只扣张的奖金部分，然后系统记录总账（注意，张总地址不能作为用户 参与游戏）
        else if (sender==_zhang.account) {
            withdrawable = _zhang.rewards;
            _zhang.rewards = 0;
            _zhang.logs.push(FundLog({
                time: time,
                tier: 4,
                balance: 0,
                change: -(int)(withdrawable)
            }));
        } 
        //李总提现，只扣李的奖金部分，然后系统记录总账（注意，李总地址不能作为用户 参与游戏）
        else if (sender==_lee.account) {
            withdrawable = _lee.rewards;
            _lee.rewards = 0;
            _lee.logs.push(FundLog({
                time: time,
                tier: 4,
                balance: 0,
                change: -(int)(withdrawable)
            }));
        } 
        //会员提现
        else {
            Node storage node = _nodes[sender];
            if (node.balance>0) {
                (bool overFlowed,uint staticRewards,uint dynamicRewards,uint rewards) = allRewardOf(sender);
                require(!overFlowed, "# Overflowed");
                uint _benefit = staticRewards + dynamicRewards;
                //计算实际得到金额
                if (node.layer<5) { //股东
                    //股东获得 85% + 股东收益 正确
                    withdrawable = _benefit * 850 / 1000 + rewards;
                } else if (node.layer>998) { //位置奖金用户
                    //998层用户 实际到账 = （动态收益+静态收益+位置奖金)*50%+（动态收益+静态收益+位置奖金)*50%*70% 正确
                    withdrawable = (_benefit + rewards) * 850 / 1000;
                } else {
                    //共生节点和其他用户 实际到账 = （动态收益+静态收益)*50%+（动态收益+静态收益)*50%*70% 正确
                    withdrawable = _benefit * 850 / 1000;
                }
                
                //计算方式 正确
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
                // Symmetrische Positionsbelohnung 对称位置奖金  (动态收益+静态收益)*50%*30%*50%
                if (node.layer<999) {
                    uint pos = _benefit * 75 / 1000; 
                    address posAddr = _prism[1999]; //对称位置 计算错误
                    //该位置没有用户时候，应该记录奖金累计数。 有用户时候，应该将该奖金加到用户rewards
                    if (posAddr!=address(0)) {
                        Node storage posNode = _nodes[sender];    
                        posNode.rewards += pos;
                    }
                    // Belohnung für jede Position 999-1000-1001 (insgesamt 2998 Personen) 999-1000-1001层 2998 个位置 
                    _luckyLogs.push(FundLog({
                        time:time,
                        balance:pos,
                        change:0,
                        tier:0
                    }));
                } 
                //其他情况，记录回购资金
                else {
                    redeemAmount += _benefit * 150 / 1000;
                }
            }
        }
        return withdrawable;
    }

    //计算可提现金额 正确
    function _withdrawable(address sender, uint time) internal view returns(uint) {
        uint withdrawable = 0;
        uint _benefit = 0;
        //计算管理员可提现 正确
        if (sender==_admin.account) {
            _benefit = _admin.rewards + dynamicRewardOf(sender);
            withdrawable = _benefit;
        } 
        //计算张总可提现金额 正确
        else if (sender==_zhang.account) {
            _benefit = _zhang.rewards;
            withdrawable = _benefit;
        } 
        //计算李总可提现 正确
        else if (sender==_lee.account) {
            _benefit = _lee.rewards;
            withdrawable = _benefit;
        } 
        //计算其他会员可提现 动态+静态+奖金（位置奖金 或者 股东奖励）正确
        else {
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
    
    //计算 TLB 流动供应量 
    function circulatingTLB() public view returns(uint) {
        return totalSupply() - totalBurnt;
    }

    //计算用户下面20层子孙节点
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

    //计算静态收益，通过检查该用户 账本方式计算。24小时发放一次静态收益
    function _staticRewardOf(address addr, uint from,uint to) internal view returns(uint) {
        uint result = 0;
        Node storage node = _nodes[addr];
        uint len = node.logs.length;
        //从后往前计算（检查用户账本，每天本金）
        for(uint i=len; i>0; i++) {
            FundLog storage _log1 = node.logs[i-1];
            uint _from = _log1.time;//前一次的记账时间
            uint _to = 0; 
            if (i==len) {//如果是账本最后一次记录，则设置to为当前时间
                _to = now;
            } else {
                _to = node.logs[i].time;//后一次的记账时间
            }
            if (from>_to || to<_from) continue;
            if (_from < from) _from = from;
            if (_to > to) _to = to;
            
            uint _diff = _to - _from;
            //一天时间为86400秒
            if (_diff>864000) {
                result = SafeMath.add(result, _log1.balance * _tiers[_log1.tier-1].staticRewards * _diff / 86400000);
            }
            // if lastlog is withdrawal
            if (_log1.change<0) break;
        }
        return result;
    }
    
    //人工触发 ，internal 方法，应该怎么调用？
    function _setInsurance(bool flag) internal returns(bool) {
        _insuranceStatus = flag;
        return _insuranceStatus;
    }
    //是否保险触发？
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
    //推荐人
    function refererOf(address sender) public view returns(address) {
        return _nodes[sender].referer;
    }
    //是否爆仓
    function isOverflowed(address sender) public view returns(bool) {
        Node storage node = _nodes[sender];
        if (node.isOverflowed) return true;
        bool overflowed = _isTriggeredInsurance();
        if (overflowed) {
            //通过保险方式 触发爆仓
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


    //计算股东收益 或者 位置奖金 或者 保险奖金（逻辑正确）
    function rewardOf(address sender) public view returns(uint) {
        Node storage node = _nodes[sender];
        uint rewards = node.rewards;
        FundLog[] storage logs = node.logs; //用户的账本
        uint _from = 0;
        uint _fromIndex = 0;
        uint len = logs.length;
        if (len>0) {
            //从后往前tranverse用户账本，找到上一次提现的操作时间。因为提现会改变奖金
            for(uint i=len-1; i>0; i--) {
                FundLog storage _log1 = logs[i-1];
                //如果有提现发生
                if (_log1.change<0) {
                    _from = _log1.time;//记录提现时间
                    _fromIndex = i;//记录提现在会计账本上的编号
                    break;
                }
            }
        }

        //对于 有奖金的位置点，查找奖金账本中的记录。    
        if (node.layer>998 && node.layer<1002) {
            for(uint i=0;i<_luckyLogs.length;i++) {
                FundLog storage _log1 = _luckyLogs[i];
                if (_log1.time>_from) {//如果上一次提现时间，在奖金统计时间中。 则将奖励 计算给用户
                    rewards += _log1.balance / 2998;
                }
            }
        }
        //对于 保险的用户 查看保险账本
        for(uint i=0;i<insurLogs.length;i++) {
            Insurance storage log = insurLogs[i];
            if (log.time>_from) {//保险发生在该用户提现以后
                for(uint k=_fromIndex; i<len; i++) {//判断该用户在保险发生以36小时内是否入金
                    FundLog storage _log1 = logs[i-1];
                    if (_log1.change>0 && _log1.time<log.time && _log1.time>log.time-7200) {//有入金，则添加奖励
                        rewards += log.amount / log.count;        
                        break;
                    }
                }
            }
        }
        return rewards;
    }

    //获取静态收益
    function staticRewardOf(address sender) public view returns(uint) {
        return _staticRewardOf(sender,0,0);
    }
    //获取动态收益
    function dynamicRewardOf(address sender) public view returns(uint) {
        if (firstAddress==address(0)) return 0;
        uint dynamicRewards = 0;
        if (sender==_zhang.account) {//张总的动态收益就是张总的rewards
            return _zhang.rewards;
        } else if (sender==_lee.account) {//李总的动态收益就是李总的rewards
            return _lee.rewards;
        } else if (sender==_admin.account) {//管理员的动态收益，按最大账户处理
            uint len = _admin.logs.length;
            // calculate PNode static rewards; 计算共生节点静态收益带给管理员的动态收益
            for(uint i=(len==0?len-1:1); i>0; i--) { //计算管理员从上一次提现到当前时间
                uint _from = 0;
                uint _to = 0;
                uint _sprigs = 0;//动态矩阵下标
                int _change = 0;
                if (len==0) {//管理员从来没有提现过
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
                
                //检查管理员每个记账时间段内，共生节点的静态收益
                uint childStatic = _staticRewardOf(firstAddress, _from, _to);
                dynamicRewards += childStatic * sprigs[0][2] / 1000; //吃20%
                if (_change<0) break;
            }
            Node storage node = _nodes[firstAddress];//共生节点
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

    //动态收益计算方式
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
        for(uint i=(len==0?len-1:1); i>0; i--) {//从后往前查看账本记录
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

    //计算会员所有可提现金额 （计算正确）
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
    //计算 可提现金额 正确
    function noderewards(address sender) public view returns(uint) {
        return _withdrawable(sender, now);
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
            uint minerPrice = _minerTiers[i][0];
            uint price = minerPrice + minerPrice * currentLayer / 1000;
            if (price==amountUsdt) {
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
            Miner storage miner = _miners[_referedMiners[account][i]];
            _total += miner.tier;
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
        uint withdrawal = _withdrawal(sender, now);
        
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
            //统计张总，李总，管理员，其他会员总出金 （管理员 出金也需要TLB）
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

    //矿工信息， 返回 算力，挖矿方式，是否激活
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

