const gameNames = { chess: "Chess", ludo: "Ludo", whot: "Whot", snooker: "Snooker" };
const gamePicks = [...document.querySelectorAll("[data-game]")];
const gameMessage = document.querySelector("#games-message");
const gameLobby = document.querySelector("#games-lobby");
const gameTable = document.querySelector("#game-table");
const gameBoard = document.querySelector("#game-board");
const tableControls = document.querySelector("#table-controls");
let selectedGame = "chess";
let currentUser = null;
let activeRoomCode = null;
let activeRoom = null;
let roomRevision = 0;
let roomPollTimer = null;
let lobbyPollTimer = null;
let selectedChessSquare = null;
let snookerAim = null;
let snookerDragging = false;

function element(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
}

function showGameMessage(text, isError = false) {
    gameMessage.textContent = text;
    gameMessage.classList.add("is-visible");
    gameMessage.classList.toggle("is-error", isError);
}

function clearGameMessage() {
    gameMessage.textContent = "";
    gameMessage.classList.remove("is-visible", "is-error");
}

async function gameApi(path, method = "GET", body) {
    const options = { method };
    if (body !== undefined) options.body = JSON.stringify(body);
    return window.authService.request(path, options);
}

function createChessState() {
    return {
        turn: 0,
        winner: null,
        board: [
            "bR", "bN", "bB", "bQ", "bK", "bB", "bN", "bR",
            "bP", "bP", "bP", "bP", "bP", "bP", "bP", "bP",
            null, null, null, null, null, null, null, null,
            null, null, null, null, null, null, null, null,
            null, null, null, null, null, null, null, null,
            null, null, null, null, null, null, null, null,
            "wP", "wP", "wP", "wP", "wP", "wP", "wP", "wP",
            "wR", "wN", "wB", "wQ", "wK", "wB", "wN", "wR"
        ]
    };
}

function shuffledDeck() {
    const cards = [];
    for (const shape of ["●", "▲", "✚", "■", "★"]) {
        for (let number = 1; number <= 14; number++) cards.push({ shape, number });
    }
    for (let count = 0; count < 5; count++) cards.push({ shape: "WHOT", number: 20 });
    for (let index = cards.length - 1; index > 0; index--) {
        const swapIndex = Math.floor(Math.random() * (index + 1));
        [cards[index], cards[swapIndex]] = [cards[swapIndex], cards[index]];
    }
    return cards;
}

function createWhotState() {
    const deck = shuffledDeck();
    return {
        turn: 0,
        winner: null,
        hands: [deck.splice(0, 5), deck.splice(0, 5)],
        drawPile: deck,
        discardPile: [deck.pop()],
        chosenShape: null
    };
}

function createInitialState(game) {
    if (game === "chess") return createChessState();
    if (game === "ludo") return { turn: 0, winner: null, dice: null, tokens: [[-1, -1, -1, -1], [-1, -1, -1, -1]] };
    if (game === "whot") return createWhotState();
    const redBalls = [];
    for (let row = 0; row < 5; row++) {
        for (let column = 0; column <= row; column++) {
            redBalls.push({ x: 535 + row * 14, y: 175 + (column - row / 2) * 15, value: 1, color: "#c92727", active: true });
        }
    }
    return {
        turn: 0,
        winner: null,
        score: [0, 0],
        cue: { x: 95, y: 175 },
        balls: [
            ...redBalls,
            { x: 265, y: 115, value: 2, color: "#e8c532", active: true },
            { x: 265, y: 235, value: 3, color: "#33895a", active: true },
            { x: 265, y: 175, value: 4, color: "#795139", active: true },
            { x: 380, y: 175, value: 5, color: "#2768c8", active: true },
            { x: 500, y: 175, value: 6, color: "#df9fb8", active: true },
            { x: 650, y: 175, value: 7, color: "#191b1a", active: true }
        ]
    };
}

function activeSide() {
    return activeRoom && String(activeRoom.myId).toLowerCase() === String(activeRoom.hostId).toLowerCase() ? 0 : 1;
}

function canPlay() {
    return activeRoom && activeRoom.status === "active" && !activeRoom.state.winner && activeRoom.state.turn === activeSide();
}

async function refreshOpenRooms() {
    try {
        const result = await gameApi("/api/games/rooms");
        const list = document.querySelector("#open-room-list");
        list.replaceChildren();
        if (!result.rooms.length) {
            list.append(element("p", "game-empty", "No open tables. Start one and invite a friend."));
            return;
        }
        for (const room of result.rooms) {
            const row = element("div", "open-room-row");
            const details = element("div", "open-room-detail");
            details.append(element("strong", "", `${gameNames[room.game]} table`));
            details.append(element("span", "", `Hosted by ${room.hostName} · ${room.code}`));
            const joinButton = element("button", "secondary-button", "Join");
            joinButton.type = "button";
            joinButton.addEventListener("click", () => joinRoom(room.code));
            row.append(details, joinButton);
            list.append(row);
        }
    } catch (error) {
        showGameMessage(error.message, true);
    }
}

async function createRoom() {
    clearGameMessage();
    try {
        const result = await gameApi("/api/games/create", "POST", {
            game: selectedGame,
            state: createInitialState(selectedGame)
        });
        await openRoom(result.code);
        showGameMessage(`Table created. Share room code ${result.code} with your opponent.`);
    } catch (error) {
        showGameMessage(error.message, true);
    }
}

async function joinRoom(code) {
    clearGameMessage();
    try {
        const result = await gameApi("/api/games/join", "POST", { code });
        await openRoom(result.code);
    } catch (error) {
        showGameMessage(error.message, true);
        await refreshOpenRooms();
    }
}

async function openRoom(code) {
    activeRoomCode = code;
    selectedChessSquare = null;
    clearGameMessage();
    gameLobby.classList.add("is-hidden");
    gameTable.classList.remove("is-hidden");
    await pollRoom(true);
    window.clearInterval(roomPollTimer);
    roomPollTimer = window.setInterval(() => pollRoom(false), 1400);
}

async function pollRoom(showErrors) {
    if (!activeRoomCode) return;
    try {
        const result = await gameApi(`/api/games/room?code=${encodeURIComponent(activeRoomCode)}`);
        const incoming = result.room;
        if (!activeRoom || incoming.revision !== roomRevision || incoming.status !== activeRoom.status) {
            activeRoom = incoming;
            roomRevision = incoming.revision;
            selectedChessSquare = null;
            renderRoom();
        }
    } catch (error) {
        if (showErrors) showGameMessage(error.message, true);
    }
}

async function submitState(nextState) {
    if (!activeRoom || !canPlay()) return;
    try {
        const result = await gameApi("/api/games/state", "POST", {
            code: activeRoom.code,
            revision: roomRevision,
            state: nextState
        });
        activeRoom.state = nextState;
        roomRevision = result.revision;
        activeRoom.revision = result.revision;
        renderRoom();
    } catch (error) {
        showGameMessage(error.message, true);
        await pollRoom(true);
    }
}

function renderRoom() {
    if (!activeRoom) return;
    document.querySelector("#table-game-label").textContent = gameNames[activeRoom.game].toUpperCase();
    document.querySelector("#table-title").textContent = activeRoom.status === "waiting"
        ? "Waiting for a player"
        : activeRoom.state.winner === null ? `${gameNames[activeRoom.game]} match` : "Game over";
    document.querySelector("#table-room-code").textContent = activeRoom.code;
    const side = activeSide();
    const playerNames = [activeRoom.hostName, activeRoom.guestName || "Waiting…"];
    const players = document.querySelector("#table-players");
    players.replaceChildren();
    for (let player = 0; player < 2; player++) {
        const chip = element("div", `table-player${activeRoom.status === "active" && activeRoom.state.turn === player ? " is-turn" : ""}`);
        chip.append(element("span", "player-seat", player === 0 ? "01" : "02"));
        chip.append(element("strong", "", playerNames[player] || "Waiting…"));
        chip.append(element("span", "player-you", player === side ? "YOU" : ""));
        players.append(chip);
    }
    const message = document.querySelector("#turn-message");
    if (activeRoom.status === "waiting") message.textContent = "Share the room code. Your board is ready when your opponent joins.";
    else if (activeRoom.state.winner !== null) message.textContent = activeRoom.state.winner === "draw" ? "The game ended in a draw." : `${playerNames[activeRoom.state.winner]} wins.`;
    else message.textContent = canPlay() ? "Your turn" : `Waiting for ${playerNames[activeRoom.state.turn] || "your opponent"}…`;
    gameBoard.className = `game-board game-board-${activeRoom.game}`;
    gameBoard.replaceChildren();
    tableControls.replaceChildren();
    if (activeRoom.status === "waiting") return;
    if (activeRoom.game === "chess") renderChess();
    if (activeRoom.game === "ludo") renderLudo();
    if (activeRoom.game === "whot") renderWhot();
    if (activeRoom.game === "snooker") renderSnooker();
}

const chessGlyphs = {
    wK: "♔", wQ: "♕", wR: "♖", wB: "♗", wN: "♘", wP: "♙",
    bK: "♚", bQ: "♛", bR: "♜", bB: "♝", bN: "♞", bP: "♟"
};

function chessPseudoMoves(board, start) {
    const piece = board[start];
    if (!piece) return [];
    const side = piece[0];
    const kind = piece[1];
    const row = Math.floor(start / 8);
    const column = start % 8;
    const moves = [];
    const addTarget = (targetRow, targetColumn) => {
        if (targetRow < 0 || targetRow > 7 || targetColumn < 0 || targetColumn > 7) return false;
        const target = targetRow * 8 + targetColumn;
        if (board[target] && board[target][0] === side) return false;
        moves.push(target);
        return !board[target];
    };
    if (kind === "P") {
        const direction = side === "w" ? -1 : 1;
        const nextRow = row + direction;
        if (nextRow >= 0 && nextRow < 8 && !board[nextRow * 8 + column]) {
            moves.push(nextRow * 8 + column);
            const homeRow = side === "w" ? 6 : 1;
            if (row === homeRow && !board[(row + direction * 2) * 8 + column]) moves.push((row + direction * 2) * 8 + column);
        }
        for (const offset of [-1, 1]) {
            const targetColumn = column + offset;
            if (targetColumn >= 0 && targetColumn < 8 && nextRow >= 0 && nextRow < 8) {
                const target = nextRow * 8 + targetColumn;
                if (board[target] && board[target][0] !== side) moves.push(target);
            }
        }
        return moves;
    }
    if (kind === "N") {
        for (const [rowOffset, columnOffset] of [[-2, -1], [-2, 1], [-1, -2], [-1, 2], [1, -2], [1, 2], [2, -1], [2, 1]]) addTarget(row + rowOffset, column + columnOffset);
        return moves;
    }
    if (kind === "K") {
        for (let rowOffset = -1; rowOffset <= 1; rowOffset++) for (let columnOffset = -1; columnOffset <= 1; columnOffset++) if (rowOffset || columnOffset) addTarget(row + rowOffset, column + columnOffset);
        return moves;
    }
    const directions = [];
    if (["R", "Q"].includes(kind)) directions.push([-1, 0], [1, 0], [0, -1], [0, 1]);
    if (["B", "Q"].includes(kind)) directions.push([-1, -1], [-1, 1], [1, -1], [1, 1]);
    for (const [rowOffset, columnOffset] of directions) {
        let targetRow = row + rowOffset;
        let targetColumn = column + columnOffset;
        while (addTarget(targetRow, targetColumn)) {
            targetRow += rowOffset;
            targetColumn += columnOffset;
        }
    }
    return moves;
}

function chessInCheck(board, side) {
    const king = board.indexOf(`${side}K`);
    if (king < 0) return true;
    const opponent = side === "w" ? "b" : "w";
    return board.some((piece, index) => piece && piece[0] === opponent && chessPseudoMoves(board, index).includes(king));
}

function chessLegalMoves(board, start) {
    const piece = board[start];
    if (!piece) return [];
    return chessPseudoMoves(board, start).filter((target) => {
        const nextBoard = [...board];
        nextBoard[target] = piece[1] === "P" && (target < 8 || target >= 56) ? `${piece[0]}Q` : piece;
        nextBoard[start] = null;
        return !chessInCheck(nextBoard, piece[0]);
    });
}

function renderChess() {
    const state = activeRoom.state;
    const side = activeSide();
    const legalTargets = selectedChessSquare === null ? [] : chessLegalMoves(state.board, selectedChessSquare);
    const boardElement = element("div", "chess-board");
    boardElement.classList.toggle("is-black-view", side === 1);
    for (let visualSquare = 0; visualSquare < 64; visualSquare++) {
        const square = side === 0 ? visualSquare : 63 - visualSquare;
        const row = Math.floor(square / 8);
        const column = square % 8;
        const button = element("button", `chess-square ${(row + column) % 2 ? "is-dark" : "is-light"}`);
        button.type = "button";
        button.setAttribute("aria-label", `${"abcdefgh"[column]}${8 - row}${state.board[square] || "empty"}`);
        if (square === selectedChessSquare) button.classList.add("is-selected");
        if (legalTargets.includes(square)) button.classList.add("is-legal");
        if (state.board[square]) {
            button.append(element("span", `chess-piece ${state.board[square][0] === "w" ? "piece-white" : "piece-black"}`, chessGlyphs[state.board[square]]));
        }
        button.addEventListener("click", () => {
            if (!canPlay()) return;
            const piece = state.board[square];
            if (selectedChessSquare !== null && legalTargets.includes(square)) {
                const nextState = structuredClone(state);
                const movedPiece = nextState.board[selectedChessSquare];
                nextState.board[square] = movedPiece[1] === "P" && (square < 8 || square >= 56) ? `${movedPiece[0]}Q` : movedPiece;
                nextState.board[selectedChessSquare] = null;
                nextState.turn = 1 - side;
                const nextSide = nextState.turn === 0 ? "w" : "b";
                const nextMoves = nextState.board.flatMap((targetPiece, index) => targetPiece && targetPiece[0] === nextSide ? chessLegalMoves(nextState.board, index) : []);
                if (!nextMoves.length) nextState.winner = chessInCheck(nextState.board, nextSide) ? side : "draw";
                selectedChessSquare = null;
                submitState(nextState);
            } else if (piece && piece[0] === (side === 0 ? "w" : "b")) {
                selectedChessSquare = square;
                renderRoom();
            } else {
                selectedChessSquare = null;
                renderRoom();
            }
        });
        boardElement.append(button);
    }
    gameBoard.append(boardElement);
    tableControls.append(element("p", "game-rule-note", "Select a piece, then a highlighted square. Pawns promote to queens."));
}

function renderLudo() {
    const state = activeRoom.state;
    const side = activeSide();
    const colors = ["#d95045", "#e2b63e"];
    const summary = element("div", "ludo-scoreboard");
    for (let player = 0; player < 2; player++) {
        const line = element("div", "ludo-player-line");
        line.append(element("span", "ludo-dot", "●"));
        line.lastChild.style.color = colors[player];
        line.append(element("strong", "", player === 0 ? activeRoom.hostName : activeRoom.guestName));
        line.append(element("span", "", state.tokens[player].map((position) => position < 0 ? "Home" : position >= 52 ? "Finished" : `${position}/52`).join(" · ")));
        summary.append(line);
    }
    gameBoard.append(summary);
    const tokenGrid = element("div", "ludo-token-grid");
    for (let player = 0; player < 2; player++) {
        for (let token = 0; token < 4; token++) {
            const position = state.tokens[player][token];
            const button = element("button", `ludo-token${player === side && canPlay() && state.dice !== null ? " can-move" : ""}`);
            button.type = "button";
            button.style.setProperty("--token-color", colors[player]);
            button.textContent = position < 0 ? "●" : position >= 52 ? "★" : String(position + 1);
            button.setAttribute("aria-label", `${player === 0 ? "Red" : "Yellow"} token ${token + 1}, ${position < 0 ? "at home" : `position ${position + 1}`}`);
            button.disabled = !canPlay() || state.turn !== player || state.dice === null;
            button.addEventListener("click", () => moveLudoToken(player, token));
            tokenGrid.append(button);
        }
    }
    gameBoard.append(tokenGrid);
    if (state.dice !== null) tableControls.append(element("p", "dice-result", `Dice: ${state.dice}`));
    const rollButton = element("button", "submit-button game-action", state.dice === null ? "Roll dice" : "Pass turn");
    rollButton.type = "button";
    rollButton.disabled = !canPlay();
    rollButton.addEventListener("click", () => {
        const nextState = structuredClone(state);
        if (nextState.dice === null) {
            nextState.dice = 1 + Math.floor(Math.random() * 6);
            const hasMove = nextState.tokens[side].some((position) => position >= 0 && position < 52 && position + nextState.dice <= 52) || (nextState.dice === 6 && nextState.tokens[side].includes(-1));
            if (!hasMove) {
                nextState.dice = null;
                nextState.turn = 1 - side;
            }
        } else {
            nextState.dice = null;
            nextState.turn = 1 - side;
        }
        submitState(nextState);
    });
    tableControls.append(rollButton);
}

function moveLudoToken(player, token) {
    if (!canPlay() || activeRoom.state.dice === null) return;
    const nextState = structuredClone(activeRoom.state);
    const die = nextState.dice;
    let position = nextState.tokens[player][token];
    if (position === -1 && die !== 6) return;
    position = position === -1 ? 0 : position + die;
    if (position > 52) return;
    nextState.tokens[player][token] = position;
    if (position < 52) {
        const trackPosition = (player * 13 + position) % 52;
        if (![0, 13, 26, 39].includes(trackPosition)) {
            for (let otherToken = 0; otherToken < 4; otherToken++) {
                const otherPosition = nextState.tokens[1 - player][otherToken];
                if (otherPosition >= 0 && otherPosition < 52 && ((1 - player) * 13 + otherPosition) % 52 === trackPosition) nextState.tokens[1 - player][otherToken] = -1;
            }
        }
    }
    nextState.winner = nextState.tokens[player].every((tokenPosition) => tokenPosition === 52) ? player : null;
    nextState.turn = die === 6 || nextState.winner !== null ? player : 1 - player;
    nextState.dice = null;
    submitState(nextState);
}

function renderWhot() {
    const state = activeRoom.state;
    const side = activeSide();
    const topCard = state.discardPile[state.discardPile.length - 1];
    const cardArea = element("div", "whot-table");
    const pile = element("div", "whot-pile");
    pile.append(element("span", "whot-shape", topCard.shape === "WHOT" ? "★" : topCard.shape));
    pile.append(element("strong", "", topCard.shape === "WHOT" ? "WHOT" : String(topCard.number)));
    pile.append(element("span", "whot-card-caption", state.chosenShape ? `Next shape ${state.chosenShape}` : "On the table"));
    cardArea.append(pile);
    const opponent = element("div", "whot-opponent");
    const opponentHand = state.hands[1 - side];
    opponent.append(element("strong", "", `${1 - side === 0 ? activeRoom.hostName : activeRoom.guestName}'s hand`));
    opponent.append(element("span", "", `${opponentHand.length} cards`));
    cardArea.append(opponent);
    gameBoard.append(cardArea);
    const hand = element("div", "whot-hand");
    hand.append(element("h3", "", "Your hand"));
    for (const [index, card] of state.hands[side].entries()) {
        const button = element("button", `whot-card${canPlay() && whotCanPlay(card, topCard, state.chosenShape) ? " can-play" : ""}`);
        button.type = "button";
        button.disabled = !canPlay() || !whotCanPlay(card, topCard, state.chosenShape);
        button.append(element("span", "whot-shape", card.shape === "WHOT" ? "★" : card.shape));
        button.append(element("strong", "", card.shape === "WHOT" ? "20" : String(card.number)));
        button.append(element("small", "", card.shape === "WHOT" ? "Wild" : card.shape));
        button.addEventListener("click", () => playWhotCard(index));
        hand.append(button);
    }
    gameBoard.append(hand);
    const drawButton = element("button", "secondary-button game-action", "Draw a card");
    drawButton.type = "button";
    drawButton.disabled = !canPlay() || whotHasMove(state, side, topCard);
    drawButton.addEventListener("click", drawWhotCard);
    tableControls.append(drawButton);
}

function whotCanPlay(card, topCard, chosenShape) {
    return card.shape === "WHOT" || card.shape === (chosenShape || topCard.shape) || card.number === topCard.number;
}

function whotHasMove(state, side, topCard) {
    return state.hands[side].some((card) => whotCanPlay(card, topCard, state.chosenShape));
}

function playWhotCard(index) {
    if (!canPlay()) return;
    const side = activeSide();
    const nextState = structuredClone(activeRoom.state);
    const card = nextState.hands[side][index];
    const topCard = nextState.discardPile[nextState.discardPile.length - 1];
    if (!whotCanPlay(card, topCard, nextState.chosenShape)) return;
    nextState.hands[side].splice(index, 1);
    nextState.discardPile.push(card);
    nextState.chosenShape = card.shape === "WHOT" ? mostCommonShape(nextState.hands[side]) : null;
    if (!nextState.hands[side].length) nextState.winner = side;
    else nextState.turn = 1 - side;
    submitState(nextState);
}

function mostCommonShape(hand) {
    const counts = new Map();
    for (const card of hand) if (card.shape !== "WHOT") counts.set(card.shape, (counts.get(card.shape) || 0) + 1);
    return [...counts.entries()].sort((left, right) => right[1] - left[1])[0]?.[0] || "●";
}

function drawWhotCard() {
    if (!canPlay()) return;
    const side = activeSide();
    const nextState = structuredClone(activeRoom.state);
    if (!nextState.drawPile.length) {
        const topCard = nextState.discardPile.pop();
        nextState.drawPile = nextState.discardPile.splice(0);
        nextState.discardPile.push(topCard);
    }
    const card = nextState.drawPile.pop();
    if (card) nextState.hands[side].push(card);
    nextState.turn = 1 - side;
    nextState.chosenShape = null;
    submitState(nextState);
}

function renderSnooker() {
    const state = activeRoom.state;
    const canvas = document.createElement("canvas");
    canvas.className = "snooker-canvas";
    canvas.width = 760;
    canvas.height = 390;
    canvas.setAttribute("aria-label", "Snooker table. Drag from the cue ball toward your target to take a shot.");
    gameBoard.append(canvas);
    drawSnooker(canvas, state);
    const shootButton = element("button", "submit-button game-action", "Shoot · Enter");
    shootButton.type = "button";
    shootButton.disabled = !canPlay() || !snookerAim;
    shootButton.addEventListener("click", () => takeSnookerShot(snookerAim));
    tableControls.append(shootButton);
    tableControls.append(element("span", "game-rule-note", "Drag from the cue ball to aim. Press Enter or select Shoot."));
    canvas.addEventListener("pointerdown", (event) => {
        if (!canPlay()) return;
        snookerDragging = true;
        canvas.setPointerCapture(event.pointerId);
        const bounds = canvas.getBoundingClientRect();
        snookerAim = {
            x: (event.clientX - bounds.left) * canvas.width / bounds.width,
            y: (event.clientY - bounds.top) * canvas.height / bounds.height
        };
        drawSnooker(canvas, state);
        shootButton.disabled = false;
    });
    canvas.addEventListener("pointermove", (event) => {
        if (!snookerDragging) return;
        const bounds = canvas.getBoundingClientRect();
        snookerAim = {
            x: (event.clientX - bounds.left) * canvas.width / bounds.width,
            y: (event.clientY - bounds.top) * canvas.height / bounds.height
        };
        drawSnooker(canvas, state);
    });
    canvas.addEventListener("pointerup", (event) => {
        if (!snookerDragging) return;
        snookerDragging = false;
        const bounds = canvas.getBoundingClientRect();
        snookerAim = {
            x: (event.clientX - bounds.left) * canvas.width / bounds.width,
            y: (event.clientY - bounds.top) * canvas.height / bounds.height
        };
        drawSnooker(canvas, state);
        shootButton.disabled = Math.hypot(snookerAim.x - state.cue.x, snookerAim.y - state.cue.y) < 8;
    });
    tableControls.append(element("p", "snooker-score", `${activeRoom.hostName}: ${state.score[0]}  ·  ${activeRoom.guestName}: ${state.score[1]}`));
}

function drawSnooker(canvas, state) {
    const context = canvas.getContext("2d");
    context.clearRect(0, 0, canvas.width, canvas.height);
    const railGradient = context.createLinearGradient(0, 0, canvas.width, canvas.height);
    railGradient.addColorStop(0, "#59402c");
    railGradient.addColorStop(0.5, "#34271f");
    railGradient.addColorStop(1, "#6c4c31");
    context.fillStyle = railGradient;
    context.fillRect(0, 0, canvas.width, canvas.height);
    const clothGradient = context.createLinearGradient(70, 40, 700, 350);
    clothGradient.addColorStop(0, "#197a55");
    clothGradient.addColorStop(0.5, "#126344");
    clothGradient.addColorStop(1, "#0d523c");
    context.fillStyle = clothGradient;
    context.fillRect(24, 24, 712, 342);
    context.strokeStyle = "rgba(226,204,151,.8)";
    context.lineWidth = 1.5;
    context.strokeRect(42, 42, 676, 304);
    context.beginPath();
    context.moveTo(265, 42);
    context.lineTo(265, 346);
    context.stroke();
    context.beginPath();
    context.arc(265, 194, 54, Math.PI / 2, Math.PI * 1.5);
    context.stroke();
    for (const [x, y] of [[32, 32], [380, 32], [728, 32], [32, 358], [380, 358], [728, 358]]) {
        context.beginPath();
        context.fillStyle = "#111916";
        context.arc(x, y, 15, 0, Math.PI * 2);
        context.fill();
        context.beginPath();
        context.strokeStyle = "rgba(223,196,137,.7)";
        context.arc(x, y, 17, 0, Math.PI * 2);
        context.stroke();
    }
    if (snookerAim) {
        const directionX = snookerAim.x - state.cue.x;
        const directionY = snookerAim.y - state.cue.y;
        const distance = Math.hypot(directionX, directionY);
        if (distance > 0) {
            const unitX = directionX / distance;
            const unitY = directionY / distance;
            context.lineCap = "round";
            context.beginPath();
            context.strokeStyle = "#8b5732";
            context.lineWidth = 6;
            context.moveTo(state.cue.x - unitX * 13, state.cue.y - unitY * 13);
            context.lineTo(state.cue.x - unitX * 118, state.cue.y - unitY * 118);
            context.stroke();
            context.beginPath();
            context.strokeStyle = "#e4d5ac";
            context.lineWidth = 3;
            context.moveTo(state.cue.x - unitX * 13, state.cue.y - unitY * 13);
            context.lineTo(state.cue.x - unitX * 25, state.cue.y - unitY * 25);
            context.stroke();
        }
    }
    context.beginPath();
    context.fillStyle = "#f6f0df";
    context.arc(state.cue.x, state.cue.y, 9, 0, Math.PI * 2);
    context.fill();
    for (const ball of state.balls) {
        if (!ball.active) continue;
        context.beginPath();
        context.fillStyle = ball.color;
        context.arc(ball.x, ball.y, 9, 0, Math.PI * 2);
        context.fill();
        context.strokeStyle = "rgba(255,255,255,.45)";
        context.stroke();
    }
    if (snookerAim) {
        context.beginPath();
        context.strokeStyle = "rgba(255,245,212,.85)";
        context.setLineDash([6, 5]);
        context.moveTo(state.cue.x, state.cue.y);
        context.lineTo(snookerAim.x, snookerAim.y);
        context.stroke();
        context.setLineDash([]);
    }
}

function takeSnookerShot(aim) {
    if (!canPlay() || !aim) return;
    const nextState = structuredClone(activeRoom.state);
    const cue = nextState.cue;
    let directionX = aim.x - cue.x;
    let directionY = aim.y - cue.y;
    const distance = Math.hypot(directionX, directionY);
    if (distance < 8) return;
    directionX /= distance;
    directionY /= distance;
    const power = Math.min(16, 2 + distance / 18);
    const movingBalls = [{ x: cue.x, y: cue.y, vx: directionX * power, vy: directionY * power, cue: true }, ...nextState.balls.map((ball, index) => ball.active ? ({ ...ball, originalIndex: index, vx: 0, vy: 0, cue: false }) : null).filter(Boolean)];
    const pockets = [[32, 32], [380, 32], [728, 32], [32, 358], [380, 358], [728, 358]];
    for (let step = 0; step < 240; step++) {
        for (const ball of movingBalls) {
            if (!ball.active) continue;
            ball.x += ball.vx;
            ball.y += ball.vy;
            ball.vx *= 0.985;
            ball.vy *= 0.985;
            if (ball.x < 45 || ball.x > 715) ball.vx *= -0.82;
            if (ball.y < 45 || ball.y > 345) ball.vy *= -0.82;
            ball.x = Math.max(45, Math.min(715, ball.x));
            ball.y = Math.max(45, Math.min(345, ball.y));
        }
        for (let leftIndex = 0; leftIndex < movingBalls.length; leftIndex++) {
            const leftBall = movingBalls[leftIndex];
            if (!leftBall.active) continue;
            for (let rightIndex = leftIndex + 1; rightIndex < movingBalls.length; rightIndex++) {
                const rightBall = movingBalls[rightIndex];
                if (!rightBall.active) continue;
                const deltaX = rightBall.x - leftBall.x;
                const deltaY = rightBall.y - leftBall.y;
                const distanceBetween = Math.hypot(deltaX, deltaY);
                if (distanceBetween > 0 && distanceBetween < 18) {
                    const normalX = deltaX / distanceBetween;
                    const normalY = deltaY / distanceBetween;
                    const speed = (leftBall.vx - rightBall.vx) * normalX + (leftBall.vy - rightBall.vy) * normalY;
                    leftBall.vx -= speed * normalX;
                    leftBall.vy -= speed * normalY;
                    rightBall.vx += speed * normalX;
                    rightBall.vy += speed * normalY;
                    leftBall.x -= normalX;
                    leftBall.y -= normalY;
                    rightBall.x += normalX;
                    rightBall.y += normalY;
                }
            }
        }
        for (const ball of movingBalls) {
            if (ball.cue || !ball.active) continue;
            const pocketed = pockets.some(([pocketX, pocketY]) => Math.hypot(ball.x - pocketX, ball.y - pocketY) < 17);
            if (pocketed) {
                ball.active = false;
                nextState.score[activeSide()] += ball.value;
            }
        }
    }
    for (const simulated of movingBalls.slice(1)) {
        const target = nextState.balls[simulated.originalIndex];
        target.x = simulated.x;
        target.y = simulated.y;
        target.active = simulated.active;
    }
    const cueState = movingBalls[0];
    nextState.cue = { x: cueState.x, y: cueState.y };
    const potted = movingBalls.slice(1).some((ball) => !ball.active);
    nextState.turn = potted ? activeSide() : 1 - activeSide();
    if (!nextState.balls.some((ball) => ball.active)) nextState.winner = nextState.score[0] === nextState.score[1] ? "draw" : nextState.score[0] > nextState.score[1] ? 0 : 1;
    snookerAim = null;
    submitState(nextState);
}

document.addEventListener("keydown", (event) => {
    if (event.key !== "Enter" || activeRoom?.game !== "snooker" || !snookerAim || !canPlay()) return;
    if (event.target instanceof HTMLInputElement || event.target instanceof HTMLTextAreaElement || event.target instanceof HTMLButtonElement) return;
    event.preventDefault();
    takeSnookerShot(snookerAim);
});

gamePicks.forEach((button) => button.addEventListener("click", () => {
    selectedGame = button.dataset.game;
    for (const pick of gamePicks) {
        const selected = pick === button;
        pick.classList.toggle("is-selected", selected);
        pick.setAttribute("aria-pressed", String(selected));
    }
}));

document.querySelector("#create-room").addEventListener("click", createRoom);
document.querySelector("#join-room-form").addEventListener("submit", (event) => {
    event.preventDefault();
    joinRoom(event.currentTarget.elements.code.value.trim().toUpperCase());
});
document.querySelector("#room-code").addEventListener("input", (event) => {
    event.currentTarget.value = event.currentTarget.value.toUpperCase().replace(/[^A-HJ-NP-Z2-9]/g, "");
});
document.querySelector("#refresh-rooms").addEventListener("click", refreshOpenRooms);
document.querySelector("#copy-room-code").addEventListener("click", async () => {
    if (!activeRoom) return;
    try {
        await navigator.clipboard.writeText(activeRoom.code);
        showGameMessage("Room code copied.");
    } catch {
        showGameMessage(`Room code: ${activeRoom.code}`);
    }
});
document.querySelector("#leave-table").addEventListener("click", () => {
    window.clearInterval(roomPollTimer);
    activeRoomCode = null;
    activeRoom = null;
    roomRevision = 0;
    snookerAim = null;
    selectedChessSquare = null;
    gameTable.classList.add("is-hidden");
    gameLobby.classList.remove("is-hidden");
    refreshOpenRooms();
});
document.querySelector("#games-sign-out").addEventListener("click", async () => {
    try {
        await window.authService.logout();
        window.location.replace("/");
    } catch (error) {
        showGameMessage(error.message, true);
    }
});

async function initializeGames() {
    try {
        const result = await window.authService.currentUser();
        currentUser = result.user;
        document.querySelector("#games-user-name").textContent = currentUser.name;
        await refreshOpenRooms();
        lobbyPollTimer = window.setInterval(() => {
            if (!activeRoomCode) refreshOpenRooms();
        }, 5000);
    } catch (error) {
        if (error.message.toLowerCase().includes("banned")) {
            window.location.replace("/appeal.html");
            return;
        }
        if (error.message.includes("Please sign in")) {
            window.location.replace("/?reason=signin");
            return;
        }
        showGameMessage(error.message, true);
    }
}

initializeGames();
