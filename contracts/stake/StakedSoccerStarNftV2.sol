//SPDX-License-Identifier: MIT

pragma solidity >=0.8.0;
pragma experimental ABIEncoderV2;

//import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeMath} from "../lib/SafeMath.sol";
import {SafeCast} from "../lib/SafeCast.sol";
import {ISoccerStarNft} from "../interfaces/ISoccerStarNft.sol";
import {IStakedSoccerStarNftV2} from "../interfaces/IStakedSoccerStarNftV2.sol";

import {VersionedInitializable} from "../deps/VersionedInitializable.sol";
import {DistributionTypes} from "../lib/DistributionTypes.sol";
import {DistributionManager} from "../misc/DistributionManager.sol";
import {SafeMath} from "../lib/SafeMath.sol";
import {SafeERC20} from "../lib/SafeERC20.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {IBalanceHook} from "../interfaces/IBalanceHook.sol";
import {IBIBNode} from "../interfaces/IBIBNode.sol";


/**
 * @title StakedToken
 * @notice Contract to stake Aave token, tokenize the position and get rewards, inheriting from a distribution manager contract
 * @author BIB
 **/
contract StakedSoccerStarNftV2 is
  IStakedSoccerStarNftV2,
  VersionedInitializable,
  DistributionManager
{
  using SafeMath for uint256;
  using SafeERC20 for IERC20;
  using SafeCast for uint;

  uint256 public constant REVISION = 0x1;
  bool public _paused;

  ISoccerStarNft public STAKED_TOKEN;
  IERC20 public REWARD_TOKEN;
  IBalanceHook public balanceHook;
  IBIBNode public NODE;

  event StakedTokenChanged(address sender, address oldValue, address newValue);
  event RewardTokenChanged(address sender, address oldValue, address newValue);
  event RewardVaultChanged(address sender, address oldValue, address newValue);
  event BalanceHookChanged(address sender, address oldValue, address newValue);
  event CoolDownDurationChanged(address sender, address oldValue, address newValue);
  event TransferOwnershipNFT(address sender, uint tokenId, address owner, address to);

  /// @notice Address to pull from the rewards, needs to have approved this contract
  address public REWARDS_VAULT;

  uint public coolDownDuration;
  uint public totalStaked;
  uint public totalPower;

  // address->token table
  mapping(address=>uint[]) public userStakedTokenTb;
  // token->staken info table
  mapping(uint=>TokenStakedInfo) public tokenStakedInfoTb;
  // user->power
  mapping(address=>uint) public userTotalPower;
  // 
  mapping(address=>bool) public allowProtocolToCallTb;

  function initialize(
    IBIBNode _node,
    ISoccerStarNft stakedToken,
    IERC20 rewardToken,
    address rewardsVault,
    uint128 distributionDuration
  ) public initializer {
    STAKED_TOKEN = stakedToken;
    REWARD_TOKEN = rewardToken;
    REWARDS_VAULT = rewardsVault;
    NODE = _node;

    // set owner
    _owner = msg.sender;

    coolDownDuration = 60;

    setDistributionDuration(distributionDuration);
  }

  modifier onlyWhenNotPaused {
      require(!_paused, "PAUSED");
      _;
  }

  function puase() public onlyOwner {
      _paused = true;
  }

  function unpause() public onlyOwner{
      _paused = false;
  }

  function setAllowProtocolToCall(address _protAddr, bool value) 
  public onlyOwner{
      allowProtocolToCallTb[_protAddr] = value;
  }

  modifier onlyAllowProtocolToCall() {
      require(allowProtocolToCallTb[msg.sender], "ONLY_PROTOCOL_CALL");
      _;
  }

  function setStakedToken(address _newValue) public onlyOwner{
    require(address(0) != _newValue, "INVALID_ADDRESS");
    emit StakedTokenChanged(msg.sender, address(STAKED_TOKEN), _newValue);
    STAKED_TOKEN = ISoccerStarNft(_newValue);
  }

  function setRewardToken(address _newValue) public onlyOwner{
    require(address(0) != _newValue, "INVALID_ADDRESS");
    emit RewardTokenChanged(msg.sender, address(REWARD_TOKEN), _newValue);
    REWARD_TOKEN = IERC20(_newValue);
  }
  
  function setRewardVault(address _newValue) public onlyOwner{
    require(address(0) != _newValue, "INVALID_ADDRESS");
    emit RewardVaultChanged(msg.sender, address(REWARDS_VAULT), _newValue);
    REWARDS_VAULT = _newValue;
  }

  function setBalanceHook(address _newValue) public onlyOwner{
    require(address(0) != _newValue, "INVALID_ADDRESS");
    emit BalanceHookChanged(msg.sender, address(balanceHook), _newValue);
    balanceHook = IBalanceHook(_newValue);
  }

  // check is the specified token is staked
  function isStaked(uint tokenId) public view override returns(bool){
      TokenStakedInfo storage tokenStakedInfo = tokenStakedInfoTb[tokenId];
      return isOwner(tokenId, address(this)) 
      && tokenStakedInfo.cooldown <= 0;
  }

  // Check if the specified token is unfreezing
  function isUnfreezing(uint tokenId) public view override returns(bool){
    uint cooldown = tokenStakedInfoTb[tokenId].cooldown;
    return cooldown > 0 && cooldown.add(coolDownDuration) >= block.timestamp;
  }

  // Check if the specified token is withdrawable
  function isWithdrawAble(uint tokenId) public view override returns(bool){
    uint cooldown = tokenStakedInfoTb[tokenId].cooldown;
    return cooldown > 0 && cooldown.add(coolDownDuration)  < block.timestamp;
  }

  function isOwner(uint tokenId, address owner)
    internal  view returns(bool){
      return (owner == IERC721(address(STAKED_TOKEN)).ownerOf(tokenId));
  }

  function getTokenPower(uint tokenId) public view returns(uint power){
      ISoccerStarNft.SoccerStar memory cardInfo = ISoccerStarNft(address(STAKED_TOKEN)).getCardProperty(tokenId);
      require(cardInfo.starLevel > 0, "CARD_UNREAL");
      // The power equation: power = gradient * 10 ^ (starLevel -1)
      return caculatePower(cardInfo.gradient, cardInfo.starLevel);
  }
 
  function caculatePower(uint gradient, uint starLevel) 
  public pure returns(uint power){
    require(gradient > 0 && gradient <= 4, "INVALID_GRADIENT");
    require(starLevel > 0 && starLevel <= 4, "INVALID_STARLEVEL");

    return gradient.exp(starLevel.sub(1));
  }

  function stake(uint tokenId) external override onlyWhenNotPaused{
    require(isOwner(tokenId, msg.sender), "NOT_TOKEN_OWNER");

    // delegate token to this contract
    IERC721(address(STAKED_TOKEN)).transferFrom(msg.sender, address(this), tokenId);

    // udpate global and token index
    _updateTokenAssetInternal(tokenId, address(this), 0, totalPower);

    uint power = getTokenPower(tokenId);
    totalPower += power;
    totalStaked++;
    userTotalPower[msg.sender] += power;

    tokenStakedInfoTb[tokenId] = TokenStakedInfo({
      owner: msg.sender,
      tokenId: tokenId,
      unclaimed: 0,
      cooldown: 0
    });

    userStakedTokenTb[msg.sender].push(tokenId);

    emit Stake(msg.sender, tokenId);

    // record extra dividend
    if(address(0) != address(balanceHook)){
      balanceHook.hookBalanceChange(msg.sender, tokenId, power);
    }
  }

  function getTokenOwner(uint tokenId) public view returns(address){
    return tokenStakedInfoTb[tokenId].owner;
  }

  /**
   * @dev Redeems staked tokens, and stop earning rewards
   * @param tokenId token to redeem to
   **/
  function redeem(uint tokenId) external override onlyWhenNotPaused{
    require(isStaked(tokenId), "TOKEN_NOT_SATKED");
    require(getTokenOwner(tokenId) == msg.sender, "NOT_TOKEN_OWNER");

    // can't allow reddem if the nft is stake as a node
    require(!NODE.isStakedAsNode(tokenId), "TOKEN_STAKED_AS_NODE");
    
    uint power = getTokenPower(tokenId);

    uint unclaimedRewards = _updateCurrentUnclaimedRewards(tokenId, power);

    // deducate the power
    totalPower -= power;
    totalStaked--;
    userTotalPower[msg.sender] -= power;

    tokenStakedInfoTb[tokenId].cooldown = block.timestamp;
    tokenStakedInfoTb[tokenId].unclaimed = unclaimedRewards;
    
    emit Redeem(msg.sender, tokenId);

    // record extra dividend
    if(address(0) != address(balanceHook)){
      balanceHook.hookBalanceChange(msg.sender, tokenId, 0);
    }
  }

  // user withdraw the spcified token
  function withdraw(uint tokenId) public override onlyWhenNotPaused{
    require(getTokenOwner(tokenId) == msg.sender, "NOT_TOKEN_OWNER");
    require(isWithdrawAble(tokenId), "NOT_WITHDRAWABLE");

    // settle rewards
    IERC20(REWARD_TOKEN).transferFrom(
      REWARDS_VAULT,
      tokenStakedInfoTb[tokenId].owner, 
      tokenStakedInfoTb[tokenId].unclaimed);
    
    // refund token
    IERC721(address(STAKED_TOKEN)).safeTransferFrom(
      address(this), tokenStakedInfoTb[tokenId].owner, tokenId);

    delete tokenStakedInfoTb[tokenId];

    // remove from user list
    uint[] storage tokenIds = userStakedTokenTb[msg.sender];
    uint indexToRm = tokenIds.length;
    for(uint i = 0; i < tokenIds.length; i++){
        if(tokenIds[i] == tokenId){
            indexToRm = i;
            break;
        }
    }
    require(indexToRm < tokenIds.length, "TOKEN_NOT_EXIST");
    for(uint i = indexToRm; i < tokenIds.length - 1; i++){
        tokenIds[i] = tokenIds[i+1];
    }
    tokenIds.pop();

    emit Withdraw(msg.sender, tokenId);
  }

  function transferOwnershipNFT(uint tokenId, address to) 
  public onlyAllowProtocolToCall {
    require(isStaked(tokenId), "TOKEN_NOT_STAKED");
    address owner = tokenStakedInfoTb[tokenId].owner;
    require(owner != to, "SAME_OWER");

    // transfer ownership
    tokenStakedInfoTb[tokenId].owner = to;

    // update old user token table
    uint[] storage tokenIds = userStakedTokenTb[owner];
    uint indexToRm = tokenIds.length;
    for(uint i = 0; i < tokenIds.length; i++){
      if(tokenIds[i] == tokenId){
          indexToRm = i;
          break;
      }
    }
    require(indexToRm < tokenIds.length, "TOKEN_NOT_EXIST");
    for(uint i = indexToRm; i < tokenIds.length - 1; i++){
      tokenIds[i] = tokenIds[i+1];
    }
    tokenIds.pop();
    // update new user token table
    userStakedTokenTb[owner].push(tokenId);

    // update user power table
    ISoccerStarNft.SoccerStar memory cardInfo = 
    ISoccerStarNft(address(STAKED_TOKEN)).getCardProperty(tokenId);
    uint power = caculatePower(cardInfo.gradient, cardInfo.starLevel);
    userTotalPower[owner] -= power;
    userTotalPower[to] += power;

    // TODO: need to transfer staken rewards?

    // update dvidend share
    if(address(0) != address(balanceHook)){
      balanceHook.hookBalanceChange(owner, tokenId, 0);
      balanceHook.hookBalanceChange(to, tokenId, power);
    }
      
    emit TransferOwnershipNFT(msg.sender, tokenId, owner, to);
  }

  function updateStarlevel(uint tokenId, uint starLevel) 
    public onlyAllowProtocolToCall {
      require(isStaked(tokenId), "TOKEN_NOT_STAKED");

      address owner = tokenStakedInfoTb[tokenId].owner;

      // redeem unclaimed reward
      uint unclaimedRewards = getUnClaimedRewardsByToken(tokenId);
      REWARD_TOKEN.safeTransferFrom(REWARDS_VAULT, owner, unclaimedRewards);
      emit ClaimReward(owner, tokenId, unclaimedRewards);

      // update nft property
      ISoccerStarNft(address(STAKED_TOKEN)).updateStarlevel(tokenId, starLevel);

      // update power
      ISoccerStarNft.SoccerStar memory cardInfo = 
        ISoccerStarNft(address(STAKED_TOKEN)).getCardProperty(tokenId);
      uint power = caculatePower(cardInfo.gradient, starLevel);
      uint oldPower = userTotalPower[owner];
      userTotalPower[owner] = power;
      if(power > oldPower){
        totalPower += power - oldPower;
      } else {
        totalPower -= power - oldPower;
      }

      // record extra dividend
      if(address(0) != address(balanceHook)){
        balanceHook.hookBalanceChange(msg.sender, tokenId, power);
      }
    }
    
  /**
   * @dev Claims reward to the specific token
   **/
  function claimRewards() external override onlyWhenNotPaused{
    uint unclaimedRewards = 0;
    uint[] storage tokenIds = userStakedTokenTb[msg.sender];
    for(uint i = 0; i < tokenIds.length; i++){
      unclaimedRewards = _updateCurrentUnclaimedRewards(tokenIds[i], getTokenPower(tokenIds[i]));
      emit ClaimReward(msg.sender, tokenIds[i], unclaimedRewards);
    }
    REWARD_TOKEN.safeTransferFrom(REWARDS_VAULT, msg.sender, unclaimedRewards);
  }

  /**
   * @dev Updates the user state related with his accrued rewards
   * @param tokenId token id
   * @param power token power
   * @return The unclaimed rewards that were added to the total accrued
   **/
  function _updateCurrentUnclaimedRewards(
    uint256 tokenId,
    uint256 power
  ) internal returns (uint256) {
    return _updateTokenAssetInternal(tokenId, address(this), power, totalPower);
  }

  // Get unclaimed rewards by the specified tokens
  function getUnClaimedRewardsByToken(uint tokenId) public view override returns(uint){
    DistributionTypes.UserStakeInput[] memory tokenStakeInputs =
      new DistributionTypes.UserStakeInput[](1);

    tokenStakeInputs[0] = DistributionTypes.UserStakeInput({
      underlyingAsset: address(this),
      tokenPower: getTokenPower(tokenId),
      totalPower: totalPower
    });

    return _getUnclaimedRewards(tokenId, tokenStakeInputs);
  }

  // Get unclaimed rewards by a set of the specified tokens
  function getUnClaimedRewardsByTokens(uint[] memory tokenIds) 
  public view override returns(uint[] memory amount){
    uint[] memory unclaimedRewards = new uint[](tokenIds.length);
    DistributionTypes.UserStakeInput[] memory tokenStakeInputs =
      new DistributionTypes.UserStakeInput[](1);

    for(uint i = 0; i < tokenIds.length; i++){
      tokenStakeInputs[0] = DistributionTypes.UserStakeInput({
            underlyingAsset: address(this),
            tokenPower: getTokenPower(tokenIds[i]),
            totalPower: totalPower
      });
      unclaimedRewards[i] = _getUnclaimedRewards(tokenIds[i], tokenStakeInputs);
    }

    return unclaimedRewards;
  }

  /**
   * @dev Return the total rewards pending to claim by an staker
   * @param staker The staker address
   * @return The rewards
   */
  function getUnClaimedRewards(address staker) external view override returns (uint256) {
    uint unclaimedRewards = 0;
    uint[] storage userStakedTokens= userStakedTokenTb[staker];
    for(uint i = 0; i < userStakedTokens.length; i++){
      unclaimedRewards += getUnClaimedRewardsByToken(userStakedTokens[i]);
    }
    return unclaimedRewards;
  }

  // Get user stake info by page
  function getUserStakedInfoByPage(address user, uint pageSt, uint pageSz) 
  public view override returns(TokenStakedInfo[] memory userStaked){
      TokenStakedInfo[] memory ret;

      uint[] storage userStakedTokens = userStakedTokenTb[user];

      if(pageSt < userStakedTokens.length){
        uint end = pageSt + pageSz;
        end = end > userStakedTokens.length ? userStakedTokens.length : end;
        ret =  new TokenStakedInfo[](end - pageSt);
        for(uint i = 0;pageSt < end; i++){
            ret[i] = tokenStakedInfoTb[userStakedTokens[pageSt]];
            pageSt++;
        } 
    }

    return ret;
  }

  /**
  * @dev returns the revision of the implementation contract
  * @return The revision
  */
  function getRevision() internal pure override returns (uint256) {
    return REVISION;
  }
}