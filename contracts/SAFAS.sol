//  simple agreement for future address space

pragma solidity 0.4.18;

import './Constitution.sol';

//  SAFAS: this contract allows stars to be delivered to buyers who have
//         purchased future stars, conditionally on technical deadlines
//         being hit.  If the deadlines are hit (as certified by a
//         vote of the galaxies), stars are released to the buyers.
//         Once a deadline passes without a certifying vote, a buyer
//         may choose to back out of the transaction, forfeiting stars
//         to claim an offline refund.
//
contract SAFAS is Ownable
{

  //  TrancheCompleted: :tranche has either been hit or missed
  //
  event TrancheCompleted(uint8 tranche, uint256 when);

  //  Forfeit: :who has chosen to forfeit :stars number of stars
  //
  event Forfeit(address who, uint16 stars);

  //  ships: public contract which stores ship state
  //  polls: public contract which registers polls
  //
  Ships public ships;
  Polls public polls;

  //  conditions: hashes for abstract proposals that must achieve majority
  //              in the polls contract
  //
  bytes32[] public conditions;

  //  deadlines: deadlines by which conditions for a tranche must have been
  //             met. if the polls does not contain a majority vote for the
  //             appropriate condition by the time its deadline is hit,
  //             stars in a commitment can be forfeit and withdrawn by the
  //             safas contract owner.
  //
  uint256[] public deadlines;

  //  timestamps: timestamps when deadlines of the matching index were
  //              hit; or 0 if not yet hit; or equal to the deadline if
  //              the deadline was missed.
  //
  uint256[] public timestamps;

  //  Commitment: structure that mirrors a signed paper contract
  //
  struct Commitment
  {
    //  tranches: number of stars to release in each tranche
    //
    uint16[] tranches;

    //  total: sum of stars in all tranches
    //
    uint16 total;

    //  rate: number of stars released per unlocked tranche per :rateUnit
    //
    uint16 rate;

    //  rateUnit: amount of time it takes for the next :rate stars to be
    //            released
    //
    uint256 rateUnit;

    //  stars: specific stars assigned to this commitment that have not yet
    //         been withdrawn
    //
    uint16[] stars;

    //  withdrawn: number of stars withdrawn by this commitment
    //
    uint16 withdrawn;

    //  forfeit: true if this commitment has forfeited any future stars
    //
    bool forfeit;

    //  forfeited: number of forfeited stars not yet withdrawn by
    //             the contract owner
    //
    uint16 forfeited;
  }

  //  commitments: per participant, the registered purchase agreement
  //
  mapping(address => Commitment) public commitments;

  //  transfers: per participant, the approved commitment transfer
  //
  mapping(address => address) public transfers;

  //  SAFAS: configure SAFAS and reference ships and polls contracts
  //
  function SAFAS(Ships _ships, bytes32[] _conditions, uint256[] _deadlines)
    public
  {
    //  sanity check: condition per deadline
    //
    require(_deadlines.length == _conditions.length);

    //  reference ships and polls contracts
    //
    ships = _ships;
    polls = Constitution(ships.owner()).polls();

    //  install conditions and deadlines, and prepare timestamps array
    //
    conditions = _conditions;
    deadlines = _deadlines;
    timestamps.length = _deadlines.length;

    //  check if the first tranche can be unlocked. most uses of this
    //  contract will set its condition to 0, unlocking it immediately
    //
    analyzeTranche(0);
  }

  //
  //  Functions for the contract owner
  //

    //  register(): register a new SAFAS commitment
    //
    function register( //  _participant: address of the paper contract signer
                       //  _tranches: number of stars unlocking per tranche
                       //  _rate: number of stars that unlock per _rateUnit
                       //  _rateUnit: amount of time it takes for the next
                       //             _rate stars to unlock
                       //
                       address _participant,
                       uint16[] _tranches,
                       uint16 _rate,
                       uint256 _rateUnit )
      external
      onlyOwner
    {
      //  for every condition/deadline, a tranche release amount must be
      //  specified, even if it's zero
      //
      require(_tranches.length == conditions.length);

      //  make sure a sane rate is submitted
      //
      require(_rate > 0);

      Commitment storage com = commitments[_participant];
      com.tranches = _tranches;
      com.total = totalStars(_tranches, 0);
      com.rate = _rate;
      com.rateUnit = _rateUnit;
    }

    //  deposit(): deposit a star into this contract for later withdrawal
    //
    function deposit(address _participant, uint16 _star)
      external
      onlyOwner
    {
      Commitment storage com = commitments[_participant];

      //  ensure we can't deposit more stars than the participant
      //  is entitled to
      //
      require( com.stars.length < (com.total - com.withdrawn) );

      //  There are two ways to deposit a star.  One way is for a galaxy to
      //  grant the SAFAS contract permission to spawn its stars.  The SAFAS
      //  contract will spawn the star directly to itself.
      //
      //  The SAFAS contract can also accept existing stars, as long as their
      //  Urbit key revision number is 0, indicating that they have not yet
      //  been started.  To deposit a star this way, grant the SAFAS contract
      //  permission to transfer ownership of the star; the contract will
      //  transfer the star to itself.
      //
      if ( ships.isOwner(ships.getPrefix(_star), msg.sender) &&
           ships.isSpawnProxy(ships.getPrefix(_star), this) &&
           !ships.isActive(_star) )
      {
        //  first model: spawn _star to :this contract
        //
        Constitution(ships.owner()).spawn(_star, this);
      }
      else if ( ships.isOwner(_star, msg.sender) &&
                ships.isTransferProxy(_star, this) &&
                ships.isActive(_star) &&
                (0 == ships.getKeyRevisionNumber(_star)) )
      {
        //  second model: transfer active, unused _star to :this contract
        //
        Constitution(ships.owner()).transferShip(_star, this, true);
      }
      else
      {
        //  star is not eligible for deposit
        //
        revert();
      }
      //  add _star to the participant's star balance
      //
      com.stars.push(_star);
    }

    //  withdrawForfeited(): withdraw one star from forfeiting _participant,
    //                       to :this contract owner's address _to
    //
    function withdrawForfeited(address _participant, address _to)
      external
      onlyOwner
    {
      Commitment storage com = commitments[_participant];

      //  withdraw is possible only if the participant has forfeited,
      //  the owner has not yet withdrawn all forfeited stars, and
      //  the participant still has stars left to withdraw
      //
      require( com.forfeit &&
               (com.forfeited > 0) &&
               (com.stars.length > 0) );

      //  star: star to forfeit (from end of array)
      //
      uint16 star = com.stars[com.stars.length-1];

      //  update contract state
      //
      com.stars.length = com.stars.length - 1;
      com.forfeited = com.forfeited - 1;

      //  then transfer the star (don't reset it because no one whom we don't
      //  trust has ever had control of it)
      //
      Constitution(ships.owner()).transferShip(star, _to, false);
    }

  //
  //  Functions for participants
  //

    //  approveCommitmentTransfer(): transfer the commitment to another address
    //
    function approveCommitmentTransfer(address _to)
      external
    {
      //  make sure the target isn't also a participant
      //
      require(0 == commitments[_to].total);
      transfers[msg.sender] = _to;
    }

    //  transferCommitment(): make an approved transfer of _from's commitment
    //                        to the caller's address
    //
    function transferCommitment(address _from)
      external
    {
      //  make sure the :msg.sender is authorized to make this transfer
      //
      require(transfers[_from] == msg.sender);

      //  make sure the target isn't also a participant
      //
      require(0 == commitments[msg.sender].total);

      //  copy the commitment to the :msg.sender and clear _from's
      //
      Commitment storage com = commitments[_from];
      commitments[msg.sender] = com;
      commitments[_from] = Commitment(new uint16[](0), 0, 0, 0,
                                      new uint16[](0), 0, false, 0);
      transfers[_from] = 0;
    }

    //  withdraw(): withdraw one star to the sender's address
    //
    //TODO  why does this overshadow withdraw(address)?
    /* function withdraw()
      external
    {
      withdraw(msg.sender);
    } */

    //  withdraw(): withdraw one star from the sender's commitment to _to
    //
    function withdraw(address _to)
      public
    {
      Commitment storage com = commitments[msg.sender];

      //  to withdraw, the participant must have a star balance,
      //  be under their current withdrawal limit, and cannot
      //  withdraw forfeited stars
      //
      require( (com.stars.length > 0) &&
               (com.withdrawn < withdrawLimit(msg.sender)) &&
               (!com.forfeit || (com.stars.length > com.forfeited)) );

      //  star: star being withdrawn
      //
      uint16 star = com.stars[com.stars.length - 1];

      //  update contract state
      //
      com.stars.length = com.stars.length - 1;
      com.withdrawn = com.withdrawn + 1;

      //  transfer :star
      //
      Constitution(ships.owner()).transferShip(star, _to, true);
    }

    //  forfeit(): forfeit all remaining stars from tranche number _tranche
    //             and all tranches after it
    //
    function forfeit(uint8 _tranche)
      external
    {
      Commitment storage com = commitments[msg.sender];

      //  the participant can forfeit if and only if the tranche is missed
      //  (its deadline has passed without confirmation), and has not
      //  previously forfeited
      //
      require( (deadlines[_tranche] == timestamps[_tranche]) &&
               !com.forfeit );

      //  forfeited: number of stars the participant will forfeit
      //
      uint16 forfeited = totalStars(com.tranches, _tranche);

      //  restrict :forfeited to the number of stars not withdrawn
      //
      if ( forfeited > (com.total - com.withdrawn) )
      {
        forfeited = (com.total - com.withdrawn);
      }

      //  update commitment metadata
      //
      com.forfeited = forfeited;
      com.forfeit = true;

      //  propagate event
      //
      Forfeit(msg.sender, forfeited);
    }

  //
  //  Public operations and utilities
  //

    //  analyzeTranche(): analyze tranche number _tranche for completion;
    //                    set :timestamps[_tranche] if either the tranche's
    //                    deadline has passed, or its conditions have been met
    //
    function analyzeTranche(uint8 _tranche)
      public
    {
      //  only analyze tranches that haven't been unlocked yet
      //
      require(0 == timestamps[_tranche]);


      //  if the deadline has passed, the tranche is missed, and the
      //  deadline becomes the tranche's timestamp.
      //
      uint256 deadline = deadlines[_tranche];
      if (block.timestamp > deadline)
      {
        timestamps[_tranche] = deadline;
        TrancheCompleted(_tranche, deadline);
        return;
      }

      //  check if the tranche condition has been met
      //
      bytes32 condition = conditions[_tranche];
      if ( //  if there is no condition, it is always met
           //
           (bytes32(0) == condition) ||
           //
           //  an real condition is met when it has achieved a majority vote
           //
           polls.abstractMajorityMap(condition) )
      {
        //  if the tranche is completed, set :timestamps[_tranche] to the
        //  timestamp of the current eth block
        //
        timestamps[_tranche] = block.timestamp;
        TrancheCompleted(_tranche, block.timestamp);
      }
    }

    //  withdrawLimit(): return the number of stars _participant can withdraw
    //                   at the current block timestamp
    //
    function withdrawLimit(address _participant)
      public
      view
      returns (uint16 limit)
    {
      Commitment storage com = commitments[_participant];

      //  for each tranche, calculate the current limit and add it to the total.
      //
      for (uint256 i = 0; i < timestamps.length; i++)
      {
        uint256 ts = timestamps[i];

        //  if a tranche hasn't completed yet, there is nothing to add.
        //
        if ( ts == 0 )
        {
          continue;
        }

        //  a tranche can't have been unlocked in the future
        //
        assert(ts <= block.timestamp);

        //  calculate the amount of stars available from this tranche by
        //  multiplying the release rate (stars per :rateUnit) by the number
        //  of rateUnits that have passed since the tranche unlocked
        //
        uint256 num = (com.rate * ((block.timestamp - ts) / com.rateUnit));

        //  bound the release rate by the tranche count
        //
        if ( num > com.tranches[i] )
        {
          num = com.tranches[i];
        }

        //  add it to the total limit
        //
        limit = limit + uint16(num);
      }

      //  limit can't be higher than the total amount of stars made available
      //
      assert(limit <= com.total);

      //  allow at least one star
      //
      if ( limit < 1 )
      {
        return 1;
      }
    }

    //  totalStars(): return the number of stars available after tranche _from
    //                in the _tranches array
    //
    function totalStars(uint16[] _tranches, uint8 _from)
      public
      pure
      returns (uint16 total)
    {
      for (uint256 i = _from; i < _tranches.length; i++)
      {
        //  simple safemath
        //
        require( (total + _tranches[i]) >= total);
        total = total + _tranches[i];
      }
    }

    //  verifyBalance: check the balance of _participant
    //
    function verifyBalance(address _participant)
      external
      view
      returns (bool correct)
    {
      Commitment storage com = commitments[_participant];

      //  return true if this contract holds as many stars as we'll ever
      //  be entitled to withdraw
      //
      return ( (com.total - com.withdrawn) == com.stars.length );
    }

    //  getTranches(): get the configured tranche sizes for a commitment
    //
    function getTranches(address _participant)
      external
      view
      returns (uint16[] tranches)
    {
      return commitments[_participant].tranches;
    }

    //  getRemainingStars(): get the stars deposited into the commitment
    //
    function getRemainingStars(address _participant)
      external
      view
      returns (uint16[] stars)
    {
      return commitments[_participant].stars;
    }
}
