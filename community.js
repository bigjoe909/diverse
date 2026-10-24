const pageLinks = [...document.querySelectorAll("[data-page]")];
const communityPages = [...document.querySelectorAll("[data-community-page]")];
const communityMessage = document.querySelector("#community-message");
let currentUser = null;
let activeCommunityPage = "posts";
let unreadPollTimer = null;
let lastUnreadMessageId = null;
let unreadSnapshotInitialized = false;
let profilePreviewObjectUrl = null;
let availableChatFriends = [];
let friendMap = null;
let friendMapMarkers = new Map();
let friendLocationTimer = null;
let locationWatchId = null;
let locationSharingEnabled = false;
let lastLocationUploadAt = 0;

function showCommunityMessage(text, isError = false) {
    communityMessage.textContent = text;
    communityMessage.classList.add("is-visible");
    communityMessage.classList.toggle("is-error", isError);
}

function clearCommunityMessage() {
    communityMessage.textContent = "";
    communityMessage.classList.remove("is-visible", "is-error");
}

function element(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
}

function displayDate(value) {
    const date = new Date(value);
    return Number.isNaN(date.getTime()) ? "" : date.toLocaleString();
}

function emptyState(container, text) {
    container.replaceChildren(element("p", "item-meta", text));
}

async function api(path, method, values) {
    const options = { method: method || "GET" };
    if (values !== undefined) options.body = JSON.stringify(values);
    return window.authService.request(path, options);
}

function makeButton(label, callback) {
    const button = element("button", "secondary-button", label);
    button.type = "button";
    button.addEventListener("click", callback);
    return button;
}

function makeCommunityItem(title, detail, meta) {
    const card = element("article", "community-item");
    if (title) card.append(element("h3", "", title));
    if (detail) card.append(element("p", "", detail));
    if (meta) card.append(element("span", "item-meta", meta));
    return card;
}

function memberAvatar(pictureUrl, name, className = "member-avatar") {
    const avatar = element("span", className);
    if (pictureUrl) {
        const image = element("img");
        image.src = `${pictureUrl}${pictureUrl.includes("?") ? "&" : "?"}v=${Date.now()}`;
        image.alt = "";
        avatar.append(image);
    } else {
        const initials = (name || "?").trim().split(/\s+/).slice(0, 2).map((part) => part[0]).join("").toUpperCase();
        avatar.append(element("span", "", initials || "?"));
    }
    return avatar;
}

function addMemberAvatar(card, pictureUrl, name) {
    const identity = element("div", "member-identity");
    const copy = element("div", "member-copy");
    while (card.firstChild) copy.append(card.firstChild);
    identity.append(memberAvatar(pictureUrl, name), copy);
    card.prepend(identity);
}

function setChatParticipant(prefix, person) {
    const image = document.querySelector(`#chat-${prefix}-picture`);
    const initial = document.querySelector(`#chat-${prefix}-initial`);
    const name = document.querySelector(`#chat-${prefix}-name`);
    name.textContent = person.name;
    if (person.pictureUrl) {
        image.src = `${person.pictureUrl}${person.pictureUrl.includes("?") ? "&" : "?"}v=${Date.now()}`;
        image.classList.remove("is-hidden");
        initial.classList.add("is-hidden");
    } else {
        image.removeAttribute("src");
        image.classList.add("is-hidden");
        initial.textContent = (person.name || "?").trim().charAt(0).toUpperCase();
        initial.classList.remove("is-hidden");
    }
}

function showChatParticipants(friend) {
    setChatParticipant("current", currentUser);
    setChatParticipant("friend", friend);
    document.querySelector("#chat-participants").classList.remove("is-hidden");
}

function openCommunityReport(userId, name) {
    const dialog = document.querySelector("#community-report-dialog");
    dialog.elements.userId.value = userId;
    document.querySelector("#community-report-title").textContent = `Report ${name}`;
    dialog.showModal();
}

function appendCommunityMedia(container, contentType, mediaUrl, label) {
    if (!contentType || !mediaUrl) return;
    if (contentType.startsWith("image/")) {
        const image = element("img", "community-media");
        image.src = mediaUrl;
        image.alt = label;
        container.append(image);
        return;
    }
    const video = element("video", "community-media");
    video.src = mediaUrl;
    video.controls = true;
    video.preload = "metadata";
    video.setAttribute("aria-label", label);
    container.append(video);
}

async function encodeMediaFile(file) {
    const dataUrl = await new Promise((resolve, reject) => {
        const reader = new FileReader();
        reader.addEventListener("load", () => resolve(reader.result));
        reader.addEventListener("error", () => reject(new Error("Could not read the selected media file.")));
        reader.readAsDataURL(file);
    });
    const encoded = String(dataUrl).split(",", 2)[1];
    if (!encoded) throw new Error("Could not read the selected media file.");
    return {
        mediaFileName: file.name,
        mediaContentType: file.type,
        mediaBase64: encoded
    };
}

function setProfilePicturePreview(url) {
    const preview = document.querySelector("#profile-picture-preview");
    const placeholder = document.querySelector("#profile-picture-placeholder");
    const removeButton = document.querySelector("#remove-profile-picture");
    if (url) {
        preview.src = url;
        preview.classList.remove("is-hidden");
        placeholder.classList.add("is-hidden");
        removeButton.disabled = false;
    } else {
        preview.removeAttribute("src");
        preview.classList.add("is-hidden");
        placeholder.classList.remove("is-hidden");
        removeButton.disabled = true;
    }
}

function updateUnreadBadge(count) {
    const badge = document.querySelector("#unread-message-count");
    badge.textContent = count > 99 ? "99+" : String(count);
    badge.classList.toggle("is-hidden", count < 1);
    badge.setAttribute("aria-label", `${count} unread ${count === 1 ? "message" : "messages"}`);
}

async function refreshUnreadMessages(notifyNew = true) {
    const result = await api("/api/chat/unread");
    updateUnreadBadge(result.count);
    const latest = result.latest;
    const latestId = latest ? String(latest.id) : null;
    if (!unreadSnapshotInitialized) {
        lastUnreadMessageId = latestId;
        unreadSnapshotInitialized = true;
        return;
    }
    if (latest && notifyNew && latestId !== lastUnreadMessageId) {
        const preview = latest.content.length > 90 ? `${latest.content.slice(0, 87)}…` : latest.content;
        showCommunityMessage(`New message from ${latest.senderName}: ${preview}`);
        if ("Notification" in window && Notification.permission === "granted") {
            const notification = new Notification(`Message from ${latest.senderName}`, { body: preview });
            notification.addEventListener("click", () => {
                window.focus();
                window.location.hash = "chat";
                notification.close();
            });
        }
    }
    lastUnreadMessageId = latestId;
}

async function loadProfile() {
    const result = await api("/api/profile/me");
    const form = document.querySelector("#profile-form");
    form.elements.name.value = result.profile.name;
    form.elements.email.value = result.profile.email;
    form.elements.bio.value = result.profile.bio || "";
    form.elements.skills.value = result.profile.skills || "";
    setProfilePicturePreview(result.profile.pictureUrl ? `${result.profile.pictureUrl}?v=${Date.now()}` : null);
}

async function loadFriends() {
    const [friendsResult, requestsResult] = await Promise.all([
        api("/api/friends"),
        api("/api/friends/requests")
    ]);
    const friendList = document.querySelector("#friend-list");
    friendList.replaceChildren();
    if (!friendsResult.friends.length) emptyState(friendList, "You haven't added any friends yet.");
    for (const friend of friendsResult.friends) {
        const card = makeCommunityItem(friend.name, friend.email);
        addMemberAvatar(card, friend.pictureUrl, friend.name);
        const actions = element("div", "item-actions");
        actions.append(makeButton("Message", () => {
            sessionStorage.setItem("dv-selected-friend", friend.id);
            window.location.hash = "chat";
        }));
        actions.append(makeButton("Report", () => openCommunityReport(friend.id, friend.name)));
        card.append(actions);
        friendList.append(card);
    }

    const requests = document.querySelector("#request-list");
    requests.replaceChildren();
    if (!requestsResult.requests.length) emptyState(requests, "No pending friend requests.");
    for (const request of requestsResult.requests) {
        const card = makeCommunityItem(request.name, request.email);
        addMemberAvatar(card, request.pictureUrl, request.name);
        const actions = element("div", "item-actions");
        actions.append(makeButton("Accept", async () => {
            await api("/api/friends/respond", "POST", { requestId: request.id, accept: true });
            await loadFriends();
            showCommunityMessage("Friend request accepted.");
        }));
        actions.append(makeButton("Decline", async () => {
            await api("/api/friends/respond", "POST", { requestId: request.id, accept: false });
            await loadFriends();
            showCommunityMessage("Friend request declined.");
        }));
        actions.append(makeButton("Report", () => openCommunityReport(request.userId, request.name)));
        card.append(actions);
        requests.append(card);
    }
    await loadPeople(document.querySelector("#friend-search").value);
}

async function loadPeople(query = "") {
    const result = await api(`/api/friends/search?q=${encodeURIComponent(query)}`);
    const list = document.querySelector("#people-list");
    list.replaceChildren();
    if (!result.people.length) {
        emptyState(list, query ? "No new people found." : "No other accounts are available yet.");
        return;
    }
    for (const person of result.people) {
        const card = makeCommunityItem(person.name, person.email);
        addMemberAvatar(card, person.pictureUrl, person.name);
        const actions = element("div", "item-actions");
        actions.append(makeButton("Send friend request", async () => {
            await api("/api/friends/request", "POST", { email: person.email });
            await loadFriends();
            showCommunityMessage(`Friend request sent to ${person.name}.`);
        }));
        actions.append(makeButton("Report", () => openCommunityReport(person.id, person.name)));
        card.append(actions);
        list.append(card);
    }
}

async function loadChatFriends() {
    const result = await api("/api/friends");
    availableChatFriends = result.friends;
    const select = document.querySelector("#chat-friend");
    const selected = sessionStorage.getItem("dv-selected-friend") || select.value;
    select.replaceChildren(new Option("Choose a friend", ""));
    for (const friend of result.friends) {
        select.add(new Option(`${friend.name} · ${friend.email}`, friend.id));
    }
    if (result.friends.some((friend) => friend.id === selected)) {
        select.value = selected;
        showChatParticipants(result.friends.find((friend) => friend.id === selected));
        await loadMessages();
    } else {
        sessionStorage.removeItem("dv-selected-friend");
        document.querySelector("#chat-participants").classList.add("is-hidden");
        emptyState(document.querySelector("#chat-thread"), "Add a friend and wait for them to accept before messaging.");
    }
}

async function loadMessages() {
    const friendId = document.querySelector("#chat-friend").value;
    sessionStorage.setItem("dv-selected-friend", friendId);
    const thread = document.querySelector("#chat-thread");
    if (!friendId) {
        document.querySelector("#chat-participants").classList.add("is-hidden");
        emptyState(thread, "Choose an accepted friend to view messages.");
        return;
    }
    const chatFriend = availableChatFriends.find((friend) => friend.id === friendId);
    if (!chatFriend) {
        document.querySelector("#chat-participants").classList.add("is-hidden");
        emptyState(thread, "Choose an accepted friend to view messages.");
        return;
    }
    showChatParticipants(chatFriend);
    const result = await api(`/api/chat/messages?friendId=${encodeURIComponent(friendId)}`);
    thread.replaceChildren();
    if (!result.messages.length) emptyState(thread, "No messages yet. Start the conversation.");
    for (const message of result.messages) {
        const isMine = message.senderId === currentUser.id;
        const row = element("div", `chat-message-row${isMine ? " is-mine" : ""}`);
        row.append(memberAvatar(message.senderPictureUrl, message.senderName, "chat-message-avatar"));
        const bubble = element("article", `chat-bubble${isMine ? " is-mine" : ""}`);
        bubble.append(element("span", "", `${message.senderName} · ${displayDate(message.createdAt)}`));
        bubble.append(element("p", "", message.content));
        row.append(bubble);
        thread.append(row);
    }
    thread.scrollTop = thread.scrollHeight;
    const unread = await api("/api/chat/unread");
    updateUnreadBadge(unread.count);
}

function initializeFriendMap() {
    if (friendMap || !window.L) return;
    friendMap = L.map("friend-map", { scrollWheelZoom: false }).setView([9.082, 8.6753], 4);
    L.tileLayer("https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png", {
        maxZoom: 18,
        attribution: "&copy; OpenStreetMap contributors"
    }).addTo(friendMap);
}

async function refreshFriendLocations() {
    if (!window.L) {
        showCommunityMessage("The map could not load. Check your internet connection and try again.", true);
        return;
    }
    initializeFriendMap();
    friendMap.invalidateSize();
    const result = await api("/api/friends/locations");
    const currentIds = new Set(result.locations.map((location) => location.id));
    const list = document.querySelector("#map-friend-list");
    list.replaceChildren();
    if (!result.locations.length) {
        list.append(element("p", "item-meta", "No friends are sharing a recent location."));
    }
    for (const location of result.locations) {
        const position = [location.latitude, location.longitude];
        let marker = friendMapMarkers.get(location.id);
        if (!marker) {
            marker = L.marker(position).addTo(friendMap);
            friendMapMarkers.set(location.id, marker);
        } else {
            marker.setLatLng(position);
        }
        const popup = document.createElement("div");
        const name = document.createElement("strong");
        name.textContent = location.name;
        const accuracy = document.createElement("p");
        accuracy.textContent = `Approx. ${Math.max(1, Math.round(location.accuracyMeters))} m accuracy · ${new Date(location.updatedAt).toLocaleTimeString()}`;
        popup.append(name, accuracy);
        marker.bindPopup(popup);

        const row = element("div", "map-friend-row");
        row.append(element("strong", "", location.name));
        row.append(element("span", "item-meta", `Updated ${new Date(location.updatedAt).toLocaleTimeString()}`));
        row.addEventListener("click", () => {
            friendMap.setView(position, 15);
            marker.openPopup();
        });
        list.append(row);
    }
    for (const [id, marker] of friendMapMarkers) {
        if (!currentIds.has(id)) {
            friendMap.removeLayer(marker);
            friendMapMarkers.delete(id);
        }
    }
}

async function stopLocationSharing() {
    locationSharingEnabled = false;
    if (locationWatchId !== null) navigator.geolocation.clearWatch(locationWatchId);
    locationWatchId = null;
    lastLocationUploadAt = 0;
    try {
        await api("/api/location", "DELETE");
        document.querySelector("#location-share-status").textContent = "Your location is not being shared.";
        document.querySelector("#toggle-location-share").textContent = "Share my location";
    } catch (error) {
        showCommunityMessage(error.message, true);
    }
}

function startLocationSharing() {
    if (!navigator.geolocation) {
        document.querySelector("#location-share-status").textContent = "Location sharing is unavailable in this browser.";
        return;
    }
    locationSharingEnabled = true;
    document.querySelector("#toggle-location-share").textContent = "Stop sharing";
    document.querySelector("#location-share-status").textContent = "Waiting for a location fix…";
    locationWatchId = navigator.geolocation.watchPosition(async (position) => {
        if (!locationSharingEnabled || Date.now() - lastLocationUploadAt < 15000) return;
        lastLocationUploadAt = Date.now();
        try {
            await api("/api/location", "POST", {
                latitude: position.coords.latitude,
                longitude: position.coords.longitude,
                accuracyMeters: Math.round(position.coords.accuracy)
            });
            document.querySelector("#location-share-status").textContent = "Sharing with accepted friends. Select Stop sharing to revoke access.";
            await refreshFriendLocations();
        } catch (error) {
            document.querySelector("#location-share-status").textContent = error.message;
            locationSharingEnabled = false;
            if (locationWatchId !== null) navigator.geolocation.clearWatch(locationWatchId);
            locationWatchId = null;
            document.querySelector("#toggle-location-share").textContent = "Share my location";
        }
    }, (error) => {
        locationSharingEnabled = false;
        if (locationWatchId !== null) navigator.geolocation.clearWatch(locationWatchId);
        locationWatchId = null;
        document.querySelector("#toggle-location-share").textContent = "Share my location";
        document.querySelector("#location-share-status").textContent = error.code === error.PERMISSION_DENIED
            ? "Location permission was denied. You can enable it in your browser settings."
            : "Could not get your location. Try again when GPS is available.";
    }, { enableHighAccuracy: false, maximumAge: 15000, timeout: 20000 });
}

async function toggleLocationSharing() {
    if (locationSharingEnabled) {
        await stopLocationSharing();
        return;
    }
    startLocationSharing();
}

async function loadPosts() {
    const result = await api("/api/posts");
    const list = document.querySelector("#post-list");
    list.replaceChildren();
    if (!result.posts.length) emptyState(list, "No posts yet. Share the first update.");
    for (const post of result.posts) {
        const card = makeCommunityItem(post.author, post.content, `${post.authorEmail} · ${displayDate(post.createdAt)}`);
        appendCommunityMedia(card, post.mediaContentType, post.mediaUrl, `Media shared by ${post.author}`);
        const actions = element("div", "item-actions post-actions");
        const likeButton = makeButton(`${post.likedByMe ? "Unlike" : "Like"} · ${post.likeCount}`, async () => {
            likeButton.disabled = true;
            try {
                const state = await api("/api/posts/like", "POST", { postId: post.id });
                post.likedByMe = state.liked;
                post.likeCount = state.likeCount;
                likeButton.textContent = `${post.likedByMe ? "Unlike" : "Like"} · ${post.likeCount}`;
                likeButton.setAttribute("aria-pressed", String(post.likedByMe));
            } catch (error) {
                showCommunityMessage(error.message, true);
            } finally {
                likeButton.disabled = false;
            }
        });
        likeButton.setAttribute("aria-pressed", String(post.likedByMe));

        const commentsButton = makeButton(`Comments · ${post.commentCount}`, () => {
            const opening = commentPanel.classList.contains("is-hidden");
            commentPanel.classList.toggle("is-hidden", !opening);
            commentsButton.setAttribute("aria-expanded", String(opening));
            if (opening && !commentsLoaded) {
                loadPostComments(post.id, commentList)
                    .then(() => { commentsLoaded = true; })
                    .catch((error) => showCommunityMessage(error.message, true));
            }
        });
        commentsButton.setAttribute("aria-expanded", "false");
        actions.append(likeButton, commentsButton);
        card.append(actions);

        const commentPanel = element("div", "post-comments is-hidden");
        const commentList = element("div", "post-comment-list");
        const commentForm = element("form", "post-comment-form");
        const commentInput = element("textarea");
        commentInput.name = "content";
        commentInput.maxLength = 1000;
        commentInput.rows = 2;
        commentInput.placeholder = "Write a comment";
        commentInput.setAttribute("aria-label", "Write a comment");
        commentInput.required = true;
        const submitComment = element("button", "secondary-button", "Comment");
        submitComment.type = "submit";
        commentForm.append(commentInput, submitComment);
        commentForm.addEventListener("submit", async (event) => {
            event.preventDefault();
            const content = commentInput.value.trim();
            if (!content) return;
            submitComment.disabled = true;
            try {
                await api("/api/posts/comments", "POST", { postId: post.id, content });
                commentInput.value = "";
                post.commentCount += 1;
                commentsButton.textContent = `Comments · ${post.commentCount}`;
                await loadPostComments(post.id, commentList);
                commentsLoaded = true;
            } catch (error) {
                showCommunityMessage(error.message, true);
            } finally {
                submitComment.disabled = false;
            }
        });
        commentPanel.append(commentList, commentForm);
        card.append(commentPanel);
        let commentsLoaded = false;
        list.append(card);
    }
}

async function loadPostComments(postId, container) {
    const result = await api(`/api/posts/comments?postId=${encodeURIComponent(postId)}`);
    container.replaceChildren();
    if (!result.comments.length) {
        emptyState(container, "No comments yet.");
        return;
    }
    for (const comment of result.comments) {
        const item = element("div", "post-comment");
        item.append(element("p", "", comment.content));
        item.append(element("span", "item-meta", `${comment.author} · ${displayDate(comment.createdAt)}`));
        container.append(item);
    }
}

async function loadDocuments() {
    const result = await api("/api/documents");
    const list = document.querySelector("#document-list");
    list.replaceChildren();
    if (!result.documents.length) emptyState(list, "No PDFs have been shared yet.");
    for (const document of result.documents) {
        const card = makeCommunityItem(document.fileName, `Uploaded by ${document.uploader}`, displayDate(document.createdAt));
        const link = element("a", "secondary-button", "Download PDF");
        link.href = `/api/documents/${encodeURIComponent(document.id)}/download`;
        card.append(link);
        list.append(card);
    }
}

async function loadListings() {
    const result = await api("/api/marketplace");
    const list = document.querySelector("#listing-list");
    list.replaceChildren();
    if (!result.listings.length) emptyState(list, "No listings yet. Add the first opportunity.");
    for (const listing of result.listings) {
        const category = listing.category.charAt(0).toUpperCase() + listing.category.slice(1);
        const price = listing.price === null ? "Contact for price" : `Price: ${Number(listing.price).toLocaleString()}`;
        const card = makeCommunityItem(listing.title, listing.description, `${category} · ${listing.seller} · ${displayDate(listing.createdAt)}`);
        appendCommunityMedia(card, listing.mediaContentType, listing.mediaUrl, `Media for ${listing.title}`);
        card.append(element("p", "item-meta", price));
        const contact = element("a", "secondary-button", `Contact ${listing.seller}`);
        contact.href = `mailto:${encodeURIComponent(listing.sellerEmail)}?subject=${encodeURIComponent(`DI-VERSE: ${listing.title}`)}`;
        card.append(contact);
        list.append(card);
    }
}

const loaders = {
    posts: loadPosts,
    profile: loadProfile,
    friends: loadFriends,
    chat: loadChatFriends,
    documents: loadDocuments,
    marketplace: loadListings,
    map: refreshFriendLocations
};

async function navigate() {
    const page = window.location.hash.slice(1) || "posts";
    const activePage = loaders[page] ? page : "posts";
    activeCommunityPage = activePage;
    if (!window.location.hash || !loaders[page]) {
        window.history.replaceState(null, "", `#${activePage}`);
    }
    for (const section of communityPages) {
        section.classList.toggle("is-hidden", section.dataset.communityPage !== activePage);
    }
    for (const link of pageLinks) {
        if (link.dataset.page === activePage) link.setAttribute("aria-current", "page");
        else link.removeAttribute("aria-current");
        link.classList.toggle("is-active", link.dataset.page === activePage);
    }
    clearCommunityMessage();
    try {
        await loaders[activePage]();
        window.clearInterval(friendLocationTimer);
        if (activePage === "map") {
            friendLocationTimer = window.setInterval(() => refreshFriendLocations().catch((error) => showCommunityMessage(error.message, true)), 30000);
        }
    } catch (error) {
        showCommunityMessage(error.message, true);
    }
}

document.querySelector("#profile-form").addEventListener("submit", async (event) => {
    event.preventDefault();
    const form = event.currentTarget;
    try {
        await api("/api/profile/update", "POST", {
            name: form.elements.name.value,
            bio: form.elements.bio.value,
            skills: form.elements.skills.value
        });
        currentUser.name = form.elements.name.value.trim();
        document.querySelector("#community-user-name").textContent = currentUser.name;
        showCommunityMessage("Your profile has been saved.");
    } catch (error) {
        showCommunityMessage(error.message, true);
    }
});

document.querySelector("#profile-picture-file").addEventListener("change", (event) => {
    const file = event.currentTarget.files[0];
    if (!file) return;
    if (file.size > 5 * 1024 * 1024) {
        event.currentTarget.value = "";
        showCommunityMessage("Profile pictures must be 5 MB or smaller.", true);
        return;
    }
    if (profilePreviewObjectUrl) URL.revokeObjectURL(profilePreviewObjectUrl);
    profilePreviewObjectUrl = URL.createObjectURL(file);
    setProfilePicturePreview(profilePreviewObjectUrl);
});

document.querySelector("#upload-profile-picture").addEventListener("click", async () => {
    const fileInput = document.querySelector("#profile-picture-file");
    const file = fileInput.files[0];
    if (!file) {
        showCommunityMessage("Choose a profile picture first.", true);
        return;
    }
    if (!file.type.startsWith("image/") || !["image/jpeg", "image/png", "image/gif", "image/webp"].includes(file.type)) {
        showCommunityMessage("Choose a JPEG, PNG, GIF, or WebP image.", true);
        return;
    }
    const button = document.querySelector("#upload-profile-picture");
    button.disabled = true;
    try {
        const media = await encodeMediaFile(file);
        const result = await api("/api/profile/picture", "POST", media);
        fileInput.value = "";
        currentUser.pictureUrl = result.pictureUrl;
        if (profilePreviewObjectUrl) URL.revokeObjectURL(profilePreviewObjectUrl);
        profilePreviewObjectUrl = null;
        setProfilePicturePreview(result.pictureUrl);
        showCommunityMessage("Profile picture updated.");
    } catch (error) {
        showCommunityMessage(error.message, true);
    } finally {
        button.disabled = false;
    }
});

document.querySelector("#remove-profile-picture").addEventListener("click", async () => {
    const button = document.querySelector("#remove-profile-picture");
    button.disabled = true;
    try {
        await api("/api/profile/picture", "DELETE");
        currentUser.pictureUrl = null;
        if (profilePreviewObjectUrl) URL.revokeObjectURL(profilePreviewObjectUrl);
        profilePreviewObjectUrl = null;
        document.querySelector("#profile-picture-file").value = "";
        setProfilePicturePreview(null);
        showCommunityMessage("Profile picture removed.");
    } catch (error) {
        showCommunityMessage(error.message, true);
        button.disabled = false;
    }
});

document.querySelector("#friend-search-form").addEventListener("submit", async (event) => {
    event.preventDefault();
    try {
        await loadPeople(document.querySelector("#friend-search").value.trim());
    } catch (error) {
        showCommunityMessage(error.message, true);
    }
});

document.querySelector("#chat-friend").addEventListener("change", () => {
    loadMessages().catch((error) => showCommunityMessage(error.message, true));
});

document.querySelector("#toggle-location-share").addEventListener("click", toggleLocationSharing);

document.querySelector("#enable-message-notifications").addEventListener("click", async () => {
    if (!("Notification" in window)) {
        showCommunityMessage("Browser notifications are not supported here.", true);
        return;
    }
    const permission = await Notification.requestPermission();
    showCommunityMessage(permission === "granted" ? "Browser alerts are enabled." : "Browser alerts were not enabled.", permission !== "granted");
});

document.querySelector("#chat-form").addEventListener("submit", async (event) => {
    event.preventDefault();
    const form = event.currentTarget;
    const content = form.elements.content.value.trim();
    const friendId = document.querySelector("#chat-friend").value;
    const sendButton = form.querySelector("button[type='submit']");
    sendButton.disabled = true;
    try {
        await api("/api/chat/send", "POST", { friendId, content });
        form.elements.content.value = "";
        await loadMessages();
    } catch (error) {
        showCommunityMessage(error.message, true);
    } finally {
        sendButton.disabled = false;
    }
});

document.querySelector("#community-report-form").addEventListener("submit", async (event) => {
    event.preventDefault();
    const form = event.currentTarget;
    try {
        await api("/api/reports", "POST", Object.fromEntries(new FormData(form)));
        form.reset();
        document.querySelector("#community-report-dialog").close();
        showCommunityMessage("Your report was sent to the admin.");
    } catch (error) {
        showCommunityMessage(error.message, true);
    }
});

document.querySelector("#close-community-report").addEventListener("click", () => document.querySelector("#community-report-dialog").close());

document.querySelector("#post-form").addEventListener("submit", async (event) => {
    event.preventDefault();
    const form = event.currentTarget;
    try {
        const file = form.elements.media.files[0];
        if (file && file.size > 20 * 1024 * 1024) {
            showCommunityMessage("Images and videos must be 20 MB or smaller.", true);
            return;
        }
        const media = file ? await encodeMediaFile(file) : {};
        await api("/api/posts", "POST", { content: form.elements.content.value.trim(), ...media });
        form.reset();
        await loadPosts();
        showCommunityMessage("Your post has been published.");
    } catch (error) {
        showCommunityMessage(error.message, true);
    }
});

document.querySelector("#document-form").addEventListener("submit", async (event) => {
    event.preventDefault();
    const form = event.currentTarget;
    const file = form.elements.file.files[0];
    if (!file) return;
    if (file.size > 10 * 1024 * 1024) {
        showCommunityMessage("PDF files must be 10 MB or smaller.", true);
        return;
    }
    try {
        const dataUrl = await new Promise((resolve, reject) => {
            const reader = new FileReader();
            reader.addEventListener("load", () => resolve(reader.result));
            reader.addEventListener("error", () => reject(new Error("Could not read the selected PDF.")));
            reader.readAsDataURL(file);
        });
        const contentBase64 = String(dataUrl).split(",", 2)[1];
        await api("/api/documents", "POST", { fileName: file.name, contentBase64 });
        form.reset();
        await loadDocuments();
        showCommunityMessage("Your PDF has been uploaded.");
    } catch (error) {
        showCommunityMessage(error.message, true);
    }
});

document.querySelector("#listing-form").addEventListener("submit", async (event) => {
    event.preventDefault();
    const form = event.currentTarget;
    try {
        const file = form.elements.media.files[0];
        if (file && file.size > 20 * 1024 * 1024) {
            showCommunityMessage("Images and videos must be 20 MB or smaller.", true);
            return;
        }
        const media = file ? await encodeMediaFile(file) : {};
        await api("/api/marketplace", "POST", {
            category: form.elements.category.value,
            title: form.elements.title.value.trim(),
            description: form.elements.description.value.trim(),
            price: form.elements.price.value,
            ...media
        });
        form.reset();
        await loadListings();
        showCommunityMessage("Your listing has been published.");
    } catch (error) {
        showCommunityMessage(error.message, true);
    }
});

document.querySelector("#community-sign-out").addEventListener("click", async () => {
    try {
        if (locationSharingEnabled) await stopLocationSharing();
        await window.authService.logout();
        window.location.replace("/");
    } catch (error) {
        showCommunityMessage(error.message, true);
    }
});

window.addEventListener("hashchange", navigate);

async function initializeCommunity() {
    try {
        const result = await window.authService.currentUser();
        currentUser = result.user;
        document.querySelector("#community-user-name").textContent = currentUser.name;
        await navigate();
        await refreshUnreadMessages(false);
        window.clearInterval(unreadPollTimer);
        unreadPollTimer = window.setInterval(async () => {
            try {
                await refreshUnreadMessages(true);
                if (activeCommunityPage === "chat" && document.querySelector("#chat-friend").value) {
                    await loadMessages();
                }
            } catch (error) {
                showCommunityMessage(error.message, true);
            }
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
        showCommunityMessage(error.message, true);
    }
}

initializeCommunity();
