pragma solidity ^0.4.24;
pragma experimental ABIEncoderV2; // Required to support an array of "bytes' which is annoying 


// Paddy: We may need to use an "interface" to do this part. Gas cost for deployment is going to get high. 
// i.e. point to a known contract that can deploy state channels, and who will return us our state channel address. 
// Then we can also have an interface for the state channel, i.e. we know how to interact with it. 
// I think the HardFork Oracle from github has an example of how to do it. 
// import "./StateChannel.sol";

/*
 * WARNING: WORK IN PROGRESS. STILL UNDER DEVELOPMENT. THIS IS A DRAFT. DO NOT USE IN PRODUCTION. NOT TESTED AT ALL. THANK YOU, PADDY. 
 * Game Rules: Six ships, all can be placed on the board (including adjacent to each other). Players take turns hitting other player's board. 
 * Important Data Structures: A commitment to every ship. 
 * Fraud proofs: Ship marked at the same location, Ship not declared as sunk. Slot not declared as hitting ship 
 * Weakness: We have to rely on a player 'detecting' that a slot opening is not correct - as we do not have full commitment to board.  
 * Why? Because sending a 10x10 grid is ~2m gas. Could have root + merkle tree; but impl complex + still significant gas overhead. 
 *
 */ 
contract BattleShipWithoutBoard {
   
    // *********** START OF STATE CHANNEL EXTRA FUNCTIONALITY  ***********
    /* 
     * 1. Store address of a new state channel (and perhaps a pointer to its code)
     * 2. Track whether the state channel is on/off (modifier will disable functionality in contract if turned on)
     * 3. Track whether this battleship game is in the main chain or a private "off-chain" network (disable some functionality if in "off-chain" network)
     */
    // StateChannel stateChannel;
    bool notprivatenetwork = false; // If this contract is deployed via a private network to simulate execution. Set this to true. Compiler can set it. 
    bool statechannelon = false; // "false" if state channel contract is not instantiated, and "true" if instantiated.  
    uint disputetime; // fixed time for the dispute process 
    uint extratime; // We need to "add time" to any timer to take into account dispute process (triggering + resolving). 
    
    // Attach to all functions in the contract. 
    // Disables all functionality if the state channel is instantiated 
    modifier disableForStateChannel() {
        require(!statechannelon);
        _;
    }
    
    // Attach to all functions in the contract "with side-effects" 
    // This should disable all functionality if this contract is deployed via private network. 
    modifier disabledInPrivateNetwork() {
        require(notprivatenetwork);
        _;
    }
    
    /* Expected Template Variables:
     * - A list of "timers". Anything that begins with "timer_" will be increased when state channel is instantiated 
     * - A list of "players". Simply an array called "players". We expect a signature from each one. 
     */
    
    // *********** END OF STATE CHANNEL EXTRA FUNCTIONALITY  ***********
    
    /* An explanation for each phase of the game 
     * SETUP - Both players swap boards. Counterparty picks one board. All other boards must be revealed. Both parties must agree to "begin game"
     * ATTACK - One player can attack a slot on the counterpartys board. Must send co-ordinate on grid. Transitions to Reveal. 
     * REVEAL - Counterparty must open slot and declare if it hit a ship or not. Full ship must be revealed if it is sunk. Performs integrity checks. Transition to ATTACK or WIN. 
     * WIN - Winner must reveal all ship commitments 
     * FRAUD - Non-winner has a fixed time period to prove fraud based on signed messages received during game + winner's ship openings. 
     * GameOver - Winner can collect their winnings. Deletes all data structures and transitions to SETUP. 
     * Note: If only one party is caught cheating - counterparty gets full bet. If both players cheated, winnings is burnt. 
     */
    enum GamePhase { Setup, Attack, Reveal, Win, Fraud, GameOver, Reset } 
    GamePhase public phase;
    
    struct Ship {
        bytes32 hash; // commitment to full ship
        uint8 k; // number of spaces 
        
        // first co-ordinate 
        uint8 x1; uint8 y1; // TODO: Do I change this to x0, and y0? Keep everything counting from zero. Slight overslight. 
        
        // second co-ordinate 
        uint8 x2; uint8 y2;
        
        // declared as sunk by counterparty
        bool sunk;
    }
    
    address[2] public players;
    address public winner;
    
    // Ship information 
    mapping (address => Ship[6]) ships; 
    uint totalShipPositions; // Set in "checkShipList"
    bool[2] playerShipsReceived; 
    
    
    // Number of games played 
    bool[2] playerReady;
    uint public round; // Number of games played 
    uint public move_ctr; // Incremented for every move in game 
    
    // Number of hits by a player
    mapping (address => uint) water_hits; 
    mapping (address => uint) ship_hits; 
    mapping (address => uint) player_balance;
    mapping (address => uint) bets; 
    mapping (address => bool) cheated; 
    
    // TODO: Implement an individual "countdown" for each player. 
    // i.e. they have an absolute time of 100 minutes to finish the game. 
    // we simply "decrement" how long it takes them to take each move. 
    // If they go over their limit; too bad. Similar to playing chess, set an upper bound on game. 
    // Also work out; "countdown" for each player vs just using challenge periods. What is more safe? 
    // With "countdown" we can just not decrement it
    
    // Whose turn is it? And when do they need to respond by? 
    uint public turn; // The "attacker" i.e. whoever takes a shot. 
    uint public challengeTime;  // absolute deadline, set after every move. 
    uint public timer_challenge; // fixed time period for each response  
    
    // Attack co-ordinates 
    uint8 x; uint8 y;

    // Restrict access to players 
    modifier onlyPlayers() {
        require(msg.sender == players[0] || msg.sender == players[1]);
        _;
    }
    
    
    // Function can only be called in this state 
    modifier onlyState(GamePhase p) {
        require(phase == p);
        _;
    }
    
    event RevealHit(address indexed player, uint8 x, uint8 y, bool hit, uint move_ctr, uint round, bytes signature);
    event RevealSunk(address indexed player, uint8 x, uint8 y, bool hit, uint move_ctr, uint round, bytes signature);
    
    // Set up the battleship contract.
    // - Address of both parties
    // - Challenge timer i.e. parties must respond with their choice within a time period 
    // - Dispute timer i.e. used in the state channel 
    constructor (address _player0, address _player1, uint _timer_challenge) public {
        players[0] = _player0;
        players[1] = _player1;
        phase = GamePhase.Setup;
        timer_challenge = _timer_challenge;
    
    }
    
    // Parties can deposit coins during the SETUP phase. 
    // Function MUST BE DISABLED if this contract is deployed via a private network
    function deposit() public onlyState(GamePhase.Setup) onlyPlayers disabledInPrivateNetwork disableForStateChannel payable {
        player_balance[msg.sender] += msg.value; 
    }
    
    // Parties can deposit coins during the SETUP phase. 
    // Function MUST BE DISABLED if this contract is deployed via a private network
    function withdraw(uint toWithdraw) public onlyPlayers disabledInPrivateNetwork disableForStateChannel payable {
        
        require(toWithdraw <= player_balance[msg.sender]);

        // Update state to reflect withdrawal 
        player_balance[msg.sender] -= toWithdraw; 
        
        // Send coins over
        msg.sender.transfer(toWithdraw);
    }
    
    // Place bet for this game. 
    // Assumption: bets can only be "increased" not "decreased" for now. Can be refunded by calling doNotPlay(); 
    function placeBet(uint bet) public onlyState(GamePhase.Setup) onlyPlayers disableForStateChannel { 
        require(player_balance[msg.sender] >= bet);
        
        player_balance[msg.sender] -= bet;
        bets[msg.sender] += bets[msg.sender] + bet; 
    }
    
    // Each party submits a ship commitment from the counterparty (and this must be signed for this round/contract!) 
    function storeShips(uint8[] _size, bytes32[] _ships, bytes _signature) public onlyState(GamePhase.Setup) onlyPlayers disableForStateChannel payable {
        
        // Who are the parties? 
        // msg.sender = party, counterparty is the other player. 
        uint counterparty = 0;
        
        // Transaction is signed by this party. Easy way to identify counterparty. 
        if(msg.sender == players[0]) {
            counterparty = 1;
        }
        
        // Only one shit of ships can be sent! 
        require(!playerShipsReceived[counterparty]);
        
        // Sanity check ships 
        checkShipList(_size, _ships); 
        
        // Hash the ship commitment 
        bytes32 sighash = sha256(_size, _ships, players[counterparty], round, address(this));
        
        // Verify counterparty signed ship commitment
        // Thus, both parties have signed this commitment! (since party had to sign tx)
        require(recover(sighash, _signature) == players[counterparty]);
        
        // All good? Store the counterparty's ships. 
        for(uint i=0; i<_size.length; i++) {
                
            // Format everything into a nice struct 
            // Gas-heavy, but easiesr for us to manage 
            ships[players[counterparty]][i] = Ship({hash: _ships[i], k: _size[i], x1: 0, y1: 0, x2: 0, y2: 0, sunk: false});
        }
        
        // Mark as ready 
        playerShipsReceived[counterparty] = true; 
    }
    
    // Declare ready to play the game (i.e. all remaining ship commitments were verified off-chain)  
    // TODO: Could be optimisied, not end of world. 
    // Of course - this implies both players have "accepted" the other parties bet. 
    function readyToPlay() public onlyPlayers disableForStateChannel onlyState(GamePhase.Setup) { 
        if(msg.sender == players[0]) {
            playerReady[0] = true;
        } else {
            playerReady[1] = true;
        }
        
        // Both players happy to play? 
        if(playerReady[0] && playerReady[1]) {
            phase = GamePhase.Attack;
            
            // Whose turn is it? 
            turn = 0; // Could be some random beacon here.  
            
            // Reset values for later games. 
            playerReady[0] = false;
            playerReady[1] = false; 
        } 
    }
    
    // One player is not happy, and can simply decide not to play for whatever reason. Refunds all bets placed so far. 
    function doNotPlay() public onlyPlayers disableForStateChannel onlyState(GamePhase.Setup) {
        
        // Refund players bets 
        player_balance[players[0]] += bets[players[0]];
        bets[players[0]] = 0;
        player_balance[players[1]] += bets[players[1]];
        bets[players[1]] = 0;
        
        // Entire game must be reset. 
        phase = GamePhase.Reset;
    }
    
    // Player picks a slot position to attack. 
    // Must be completed within a time period 
    function attack(uint8 _x, uint8 _y) public disableForStateChannel onlyState(GamePhase.Attack) {
        
        // Store attack slot (if it is this player's turn)
        if(msg.sender == players[turn]) {
            
            // Valid slot? 
            if(checkValidSlot(_x, _y)) {
            
                // Store attack co-ordinates 
                x = _x;
                y = _y;
                
                // Transition to reveal phase 
                changeGamePlayPhase(false); 
            }
        }
    }
    
    // Counterparty reveals slot. Marked as water or ship. No ship was sunk. 
    function revealslot(bool _b, bytes _signature) public disableForStateChannel onlyState(GamePhase.Reveal){
        
        // Who is the counterparty? 
        uint counterparty = (turn + 1) % 2; 
        
        // We require an EXPLICIT signature - to be used by fraud proof
        // Because this must be signed by counterparty - caller of this function doesn't matter. 
        // Slot, water/ship, counterparty address, move ctr (incremented every phase change in contract), round, this contract address
        bytes32 sighash = sha256(x,y,_b,players[counterparty], move_ctr, round, address(this));
        require(recover(sighash, _signature) == players[counterparty]);
 
        // Hit a ship or water? 
        if(_b) {
            ship_hits[players[turn]] += 1;
            
            // Sanity check number of shots 
            if(ship_hits[players[turn]] >= totalShipPositions) {
                fraudDetected(counterparty);
                return;
            }
            
        } else {
            water_hits[players[turn]] += 1;
            
            // Sanity check number of shots 
            if(water_hits[players[turn]] >= (100 - totalShipPositions)) {
                fraudDetected(counterparty);
                return; 
            }
        }
            
        // All good? Publish signed message (easy fetching)
        emit RevealHit(players[counterparty], x, y, _b, move_ctr, round, _signature);
        
        // Game not finished... 
        changeGamePlayPhase(false);
    }
    
        
    // Counterparty reveals slot + that a ship was sunk. 
    function revealsunk(uint _shipindex, uint8 _x1, uint8 _y1, uint8 _x2, uint8 _y2, uint _r, bytes _signature) public disableForStateChannel onlyState(GamePhase.Reveal) {
        
        // Who is the counterparty? 
        uint counterparty = (turn + 1) % 2; 
        
        // We require an EXPLICIT signature to be used by fraud proof
        // Again, because this is signed by counterparty, caller of function doesn't matter. 
        // location1,location2,nonce,counterparty address, ship index, move counter, round, contract address 
        bytes32 sighash = sha256(_x1,_y1,_x2,_y2,_r,_shipindex,move_ctr,round, address(this));
        require(recover(sighash, _signature) == players[counterparty]);
        
        // Sanity check ships... 
        if(!checkShipQuality(_x1, _y1, _x2, _y2, _r, _shipindex, players[counterparty])) {
            // Not a valid ship opening (or the ship itself is invalid).
            // Counterparty should not have signed this statement; considered cheating
            fraudDetected(counterparty);
            return; 
        }
        
        // Recording that a ship location was hit 
        ship_hits[players[turn]] += 1;
            
        // Sanity check number of shots 
        if(ship_hits[players[turn]] >= totalShipPositions) {
            fraudDetected(counterparty);
            return;
        }
        
        // Is this ship actually on the attacked slot? 
        if(!checkAttackSlot(x,y, _x1, _y1, _x2, _y2)) { 
            
            // Ship is not on this attack slot, but signed by counterparty
            // for this move. Considered cheating. 
            fraudDetected(counterparty);
            return; 
        }
            
        // Time to finish the game 
        changeGamePlayPhase(false);
    }
    
    
    // Check whether all ships for a given player have been sank! 
    // Solidity rant: Should be in revealsunk(), but forced to create a new function due to callstack issues. 
    function sankAllShips(address player) public onlyPlayers disableForStateChannel {
        require(phase == GamePhase.Attack || phase == GamePhase.Reveal); 
        
        // Check if all ships are sunk 
        for(uint i=0; i<ships[player].length; i++) {
            if(!ships[player][i].sunk) {
                return;
            }
        }
        
        // Looks like all ships are sunk! 
        changeGamePlayPhase(true);
    }
    
    // Internal function to transition game phase after a move. 
    function changeGamePlayPhase(bool finished) internal {

        // Set a new challenge time
        // TODO: "now" relies on "block.timestamp" - problems in state channel and private network will occur
        challengeTime = now + timer_challenge; 
        move_ctr = move_ctr + 1;
        
        // Is it game over? 
        // Winner is player who "attacked" as they sunk a battleship. 
        if(finished) {
            phase = GamePhase.Win; 
            winner = players[turn];
            return;
        }
        
        if(GamePhase.Attack == phase) {
                   
            // "turn" represents who is the attacker
            // Mod 2, allows it to go 0,1,0,1, etc.
            turn = (turn + 1) % 2; 
            phase = GamePhase.Reveal;
        } else {
            phase = GamePhase.Attack;
        }
    }

    
    // Sanity check the claimed size of all ships 
    function checkShipList(uint8[] _size, bytes32[] _ships) internal {
        
        // We are expecting six ships 
        require(_size.length == 6);
        require(_ships.length == 6);
        
        // Battleship sizes from https://www.thesprucecrafts.com/the-basic-rules-of-battleship-411069
        require(_size[0] == 5); // Carrier 
        require(_size[1] == 4); // Battleship 
        require(_size[2] == 3); // Cruiser
        require(_size[3] == 3); // Submarine 
        require(_size[4] == 2); // Destoryer 
        
        // Total ship positions for each player 
        totalShipPositions = _size[0] + _size[1] + _size[2]  + _size[3] + _size[4];
    
        // No need for return. Require should break execution if any fail. 
    }
    
    // We must check that given the ship positions; that the attack was indeed on this ship
    function checkAttackSlot(uint8 _x, uint8 _y, uint8 _x1, uint8 _y1, uint8 _x2, uint8 _y2) internal pure returns (bool) {
        
        // Is the ship horizontal? 
        if(_x1 == _x2) {
            
            // Ship is horizontal - so attack slot _x must be the same. 
            if(_x != _x1) { return false; }
            
            // Example of valid position: _x can be between any of the slots 
            // 9 >= 8 => 7 
            // 7 <= 8 <= 9
            if((_y1 >= _y && _y >= _y2) || (_y1 <= _y && _y <= _y2)) {
                return true; 
            }
        }
        
        // Is the ship vertical? 
        if(_y1 == _y2) {
            
            // Ship is horizontal
            if(_y != _y1) { return false; }
            
            // Example of valid position: _x can be between any of the slots 
            // 9 >= 8 => 7 
            // 7 <= 8 <= 9
            if((_x1 >= _x  && _x >= _x2) || (_x1 <= _x && _x <= _x2)) {
                return true; 
            }
        }
        
        // Ship was not horizontal or vertical 
        return false; 
    }
    
    // We count from 0,...,9 for each grid position! 
    function checkValidSlot(uint8 _x, uint _y) internal pure returns(bool) {

        // Should be on the 10x10 Grid. 
        // We count from 0,...,9
        if(_x < 0 || _x >= 10) { return false; }
        if(_y < 0 && _y >= 10) { return false; }
        
        return true; 
    }
    
    // Check ship conditions. Should be in a straight line and on all valid slots. 
    function checkShipQuality(uint8 _x1, uint8 _y1, uint8 _x2, uint8 _y2, uint _r,  uint _shipindex, address _counterparty) internal view returns (bool) {
        
         // Look up counterparty's ship and check commitment
        uint8 k;
        
         // Is this the ship we are expecting? 
        if(ships[_counterparty][_shipindex].hash == sha256(_x1, _y1, _x2, _y2, _r,_counterparty, round, address(this))) {
            k = ships[_counterparty][_shipindex].k;
        } else {
            return false; 
        }
        
        // Is this ship within the board?
        // Throws if not valid 
        if(!checkValidSlot(_x1, _y1)) { return false; }
        if(!checkValidSlot(_x2, _y2)) { return false; }
        
        return checkLine(_x1, _y1, _x2, _y2, k);
    }
    
    // Check whether a list of points are indeed in a straight line 
    function checkLine(uint8 _x1, uint8 _y1, uint8 _x2, uint _y2, uint8 k) internal pure returns (bool) {
                // Confirm if it is in a straight line or not. 
        bool line = false;
            
        // Is this ship veritcal? 
        if(_x1 == _x2) { 
            
             // Vertical ships must always increment (0 top 9 bottom)
             // So we'd expect _y1 near top of board, and _y2 near bottom of board. 
            if(_y2 > _y1) {
                
                // OK it should be exactly k slots in length
                if(_y2 - _y1 == k) {
                    line = true;
                }
            }
        }
        
        //Is this ship horizontal? 
        if(_y1 == _y2) {
         
            // Horizontal ships must always increment (0 left, 9 right)
            if(_x2 > _x1) {
             
                // OK it should be exactly k slots in length
                if(_x2 - _x1 == k) {
                    line = true;
                }
            } 
        }
        
        // Must be in a straight line 
        return line;
    }
    
    // Fraud was detected during the game. 
    // We already know one player cheated. So we can declare "non-cheater" as the winner, and require them to reveal their board.
    function fraudDetected(uint cheater) internal {
        uint noncheater = (cheater + 1) % 2;
        cheated[players[cheater]] = true; 
        winner = players[noncheater];
        phase = GamePhase.Win;
        challengeTime = now + timer_challenge; // Winner has a fixed time period to open ships 
    }
    
    // Winner must open their ships. 
    // We perform sanity checks on all opened ships.
    // However we cannot check for everything! Only basic things (i.e. straight line)
    // Counterparty is provided time to do a real check and submit fraud proof if necessary
    function openships(uint8[] _x1, uint8[] _y1, uint8[] _x2, uint8[] _y2, uint[] _r) public onlyPlayers disableForStateChannel onlyState(GamePhase.Win) {
        
        require(msg.sender == winner);
        
        // We are expecting ALL ship openings! 
        // If a "ship" was already sunk, it can be filled with 0,0,0,0,0. 
        // TODO: This could be optimised, but not fully necessary. Simple is better. 
        require(_x1.length == ships[winner].length && _y1.length == ships[winner].length && 
                _x2.length == ships[winner].length && _y2.length == ships[winner].length && 
                _r.length == ships[winner].length);
                
        // Go through each ship... store if necessary! 
        for(uint i=0; i<ships[winner].length; i++) {
            
            // Only store ships that have not yet been sunk 
            if(!ships[winner][i].sunk) {
                
                // Sanity check ships... 
                if(!checkShipQuality(_x1[i], _y1[i], _x2[i], _y2[i], _r[i], i, winner)) {
             
                    //TODO: What if the quality doesn't check out? then we need to end the game... 
                    cheated[winner] = true;
                    phase = GamePhase.GameOver;
                    return; 
                }
                
                // Store ship. Crucial: It cannot be declared as sunk! 
                ships[winner][i].x1 = _x1[i];
                ships[winner][i].y1 = _y1[i]; 
                ships[winner][i].x2 = _x2[i];
                ships[winner][i].y2 = _y2[i]; 
            }
        }
        
        // No fraud detected on opened ships. Let the counterparty have their turn. 
        phase = GamePhase.Fraud; 
        challengeTime = now + timer_challenge;
    }
    
    // Finish the game, send winner their coins, and go back to set up. 
    function finishGame() public onlyPlayers disableForStateChannel onlyState(GamePhase.Fraud)  {
        
        // Challenge period has expired? 
        if(now > challengeTime) {
            require(sendWinnings(winner));
        }
        
    }
    
    // Both players cheated. Forfeit their bets (or do something here). 
    function GameOver() public onlyPlayers disableForStateChannel onlyState(GamePhase.GameOver) {
        
        // Both players forfeit their bets. 
        bets[players[0]] = 0;
        bets[players[1]] = 0;
        
        phase = GamePhase.Reset;
    
    }
    
    // Send the final winnings 
    function sendWinnings(address sendTo) internal returns(bool) {
    
        uint winnings = bets[players[0]] + bets[players[1]]; 
        bets[players[0]] = 0;
        bets[players[1]] = 0;
        player_balance[sendTo] = winnings; 
        
        // Time to reset the entire game... dedicate a full transaction to it. Avoid out of gas problems. 
        phase = GamePhase.Reset; 
        
        return true;
    }
    
    // All moves have a "time-out". If the player times out, we can finish the game early
    // "or" claim all the winnings! 
    function fraudChallengeExpired() public onlyPlayers disableForStateChannel {
        require(now >= challengeTime);
        
        // In ATTACK - we care about whose "turn" it is to play 
        if(phase == GamePhase.Attack) {
            
            // We have detected fraud! They should have finished their turn by now.  
            fraudDetected(turn);
            
        }
        
        // In REVEAL - we care about the counterparty of the turn 
        if(phase == GamePhase.Reveal) {
            
            // Counterparty should have finished their  turn by now. 
            // So we consider it "fraud" if the time limit is up. 
            fraudDetected((turn + 1) % 2);
        }
        
        // In WIN - we care about the winner revealing their board!
        if(phase == GamePhase.Win) {
            
            // Only the loser should call this fraud! 
            require(winner != msg.sender);
            
            // If both players cheated, we just go to "gameover"
            if(cheated[msg.sender]) {
                GameOver();
            } else {
                require(sendWinnings(msg.sender));
            }
        }
    }

    // Did counterparty not declare a ship was hit? 
    // Requires: List of signed messages from counterparty on slots
    // Look up ship opening, identify its slots. Check if there is a signed message for each slot. Yup? Not declared as sunk. 
    function fraudDeclaredNotHit(uint _shipindex, uint8 _x, uint8 _y, uint _move_ctr, bytes _signature) public onlyPlayers disableForStateChannel {
        
        // We can check this fraud during the game or when it has finished.
        // In both cases; the ship opening must be in the contract 
        require(phase == GamePhase.Attack || phase == GamePhase.Reveal || phase == GamePhase.Fraud);
        require(msg.sender != winner); 
        
        // Who is the caller and the counterparty? 
        address counterparty; 
        if(msg.sender == players[0]) {
            counterparty = players[1];
        } else {
            counterparty = players[0];
        }
        
        // Confirm a ship exists for this index 
        require(_shipindex >= 0 && _shipindex < ships[counterparty].length);
        
        // Check the ship was stored in the contract 
        // One position must be greater than 0....
        require(ships[counterparty][_shipindex].x1 > 0 || ships[counterparty][_shipindex].y1 > 0 || 
                ships[counterparty][_shipindex].x2 > 0 || ships[counterparty][_shipindex].x2 > 0);
                
        // If this represents a valid attack slot... lets see what counterparty signed. 
        bool valid = checkAttackSlot(_x,_y,ships[counterparty][_shipindex].x1, ships[counterparty][_shipindex].y1, 
                                           ships[counterparty][_shipindex].x2, ships[counterparty][_shipindex].y2);
        
        // Valid attack? (Split for readability)                                   
        if(valid) {
            
            // Lets finally check if the counterparty marked this slot as water during the game 
            bytes32 sighash = sha256(_x,_y,false, _move_ctr, round, address(this));
            require(recover(sighash, _signature) == counterparty);
            
            // Yup! Winner cheated! 
            cheated[counterparty] = true;
            
            // If both players cheated, then we go into "GameOver" 
            if(cheated[players[0]] && cheated[players[1]]) {
                GameOver();
                return;
            }
            
            // Looks like only the winner cheated... Loser gets the bet! 
            // THIS IS OK. Only loser can call this function! 
            sendWinnings(msg.sender);
        }
    }
    
    // Only designed for end of game! 
    // *** Ship slot information ***
    // _shipindex refers to a ship already stored in this contract. 
    // _move_ctr refers to the "move counter" that was signed when each slot was revealed (order is important! from top to bottom, or left to right). 
    // _signatures refers to the signatures by the counterparty when revealing the ship slot. 
    // If the ship was not declared as sunk, but all slot locations are revealed as hit, then winner cheated. 
    // We do not need to check if any slot locations were revealed as water - as fraudDeclaredNotHit() can be used instead. 
    // 
    function fraudDeclaredNotSunk(uint _shipindex, uint[] _move_ctr, bytes[] _signatures) public onlyPlayers disableForStateChannel {
        
        // We can check this fraud during the game or when it has finished.
        // In both cases; the ship opening must be in the contract 
        require(phase == GamePhase.Fraud);
        require(msg.sender != winner); 

        
        // Confirm this is a real ship identifier
        require(_shipindex < ships[winner].length);
        
        // Has the ship been marked as sunk? 
        require(!ships[winner][_shipindex].sunk);
            
        // We know it is a line... so we just now check every signature 
        // Vertical
        if(ships[winner][_shipindex].x1 == ships[winner][_shipindex].x2) {
            
            // OK we need to now check that the winner signed a "reveal" message for every slot 
            // First - lets make sure we have enough signatures to check! 
            require(ships[winner][_shipindex].k == _signatures.length && ships[winner][_shipindex].k == _move_ctr.length);
                
            // Go through every slot. We know that "y" should be incremented as this is a veritical ship. 
            for(uint i=0; i<_signatures.length; i++) {
                bytes32 sighash = sha256(ships[winner][_shipindex].x1,ships[winner][_shipindex].y1+i,true,_move_ctr[i],round,address(this));
                
                require(recover(sighash, _signatures[i]) == winner);
            }
            
            // YUP! The winner did declare all ship slots as hit. But did not declare the ship as sunk.  
            
        } else { // The ship was must horizontal. It wouldn't be stored in contract unless we checked it well-formed! 
                        
            // OK we need to now check that the winner signed a "reveal" message for every slot 
            // First - lets make sure we have enough signatures to check! 
            require(ships[winner][_shipindex].k == _signatures.length && ships[winner][_shipindex].k == _move_ctr.length);
                
            // Go through every slot. We know that "x" should be incremented as this is a horizontal ship. 
            for(i=0; i<_signatures.length; i++) {
                sighash = sha256(ships[winner][_shipindex].x1+i,ships[winner][_shipindex].y1,true,_move_ctr[i],round,address(this));
                require(recover(sighash, _signatures[i]) == winner);
            }
            
            // Again yay! the winner did declare all ship slots as hit. But did not declare the ship as sunk. 
            
        }
        
        // We made it this far... so the winner must have cheated! 
        cheated[winner] = true;
            
        // If both players cheated, then we go into "GameOver" 
        if(cheated[players[0]] && cheated[players[1]]) {
            GameOver();
            return;
        }
            
        // Looks like only the winner cheated... Loser gets the bet! 
        // THIS IS OK. Only loser can call this function! 
        sendWinnings(msg.sender);
    }
    
    // Reset and destory all variables in this game. Start afresh (do not delete balance!)
    function reset() public onlyPlayers onlyState(GamePhase.Reset) {
        // TODO: NOT COMPLETED.
        
        // Increment round. 
        round = round + 1; 
    }
    
  
  // Borrowed from: https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-solidity/master/contracts/ECRecovery.sol  
  /**
   * @dev Recover signer address from a message by using their signature
   * @param _hash bytes32 message, the hash is the signed message. What is recovered is the signer address.
   * @param _signature bytes signature, the signature is generated using web3.eth.sign()
   */
  function recover(bytes32 _hash, bytes _signature)
    internal
    pure
    returns (address)
  {
    bytes32 r;
    bytes32 s;
    uint8 v;

    // Check the signature length
    if (_signature.length != 65) {
      return (address(0));
    }

    // Divide the signature in r, s and v variables
    // ecrecover takes the signature parameters, and the only way to get them
    // currently is to use assembly.
    // solium-disable-next-line security/no-inline-assembly
    assembly {
      r := mload(add(_signature, 32))
      s := mload(add(_signature, 64))
      v := byte(0, mload(add(_signature, 96)))
    }

    // Version of signature should be 27 or 28, but 0 and 1 are also possible versions
    if (v < 27) {
      v += 27;
    }

    // If the version is correct return the signer address
    if (v != 27 && v != 28) {
      return (address(0));
    } else {
      // solium-disable-next-line arg-overflow
      return ecrecover(_hash, v, r, s);
    }
  }

  /**
   * toEthSignedMessageHash
   * @dev prefix a bytes32 value with "\x19Ethereum Signed Message:"
   * and hash the result
   */
  function toEthSignedMessageHash(bytes32 _hash)
    internal
    pure
    returns (bytes32)
  {
    // 32 is the length in bytes of hash,
    // enforced by the type signature above
    return keccak256(
      abi.encodePacked("\x19Ethereum Signed Message:\n32", _hash)
    );
  }
}
