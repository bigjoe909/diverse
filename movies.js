const movieMessage = document.querySelector("#movies-message");
const movieList = document.querySelector("#movie-list");
const uploadForm = document.querySelector("#movie-upload-form");
const uploadButton = document.querySelector("#movie-upload-button");
const uploadProgress = document.querySelector("#movie-upload-progress");
const uploadStatus = document.querySelector("#movie-upload-status");

function element(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
}

function showMovieMessage(text, isError = false) {
    movieMessage.textContent = text;
    movieMessage.classList.add("is-visible");
    movieMessage.classList.toggle("is-error", isError);
}

async function movieApi(path, method = "GET", body) {
    const options = { method };
    if (body !== undefined) options.body = JSON.stringify(body);
    return window.authService.request(path, options);
}

function dateLabel(value) {
    const date = new Date(value);
    return Number.isNaN(date.getTime()) ? "" : date.toLocaleDateString();
}

function formatBytes(value) {
    if (value >= 1024 * 1024 * 1024) return `${(value / (1024 * 1024 * 1024)).toFixed(1)} GB`;
    return `${Math.ceil(value / (1024 * 1024))} MB`;
}

function initials(name) {
    return (name || "?").trim().split(/\s+/).slice(0, 2).map((part) => part[0]).join("").toUpperCase() || "?";
}

async function loadMovies() {
    const result = await movieApi("/api/movies");
    movieList.replaceChildren();
    if (!result.movies.length) {
        movieList.append(element("p", "movie-empty", "No movies have been shared yet."));
        return;
    }
    for (const movie of result.movies) {
        const card = element("article", "movie-card");
        const player = element("video", "movie-player");
        player.controls = true;
        player.preload = "metadata";
        player.src = movie.streamUrl;
        player.setAttribute("aria-label", movie.title);
        const details = element("div", "movie-card-details");
        details.append(element("h3", "", movie.title));
        if (movie.description) details.append(element("p", "", movie.description));
        const byline = element("div", "movie-uploader");
        const avatar = element("span", "member-avatar");
        if (movie.uploaderPictureUrl) {
            const image = element("img");
            image.src = movie.uploaderPictureUrl;
            image.alt = "";
            avatar.append(image);
        } else {
            avatar.append(element("span", "", initials(movie.uploaderName)));
        }
        byline.append(avatar, element("span", "", `${movie.uploaderName} · ${formatBytes(movie.fileSize)} · ${dateLabel(movie.createdAt)}`));
        details.append(byline);
        if (movie.uploaderId !== window.currentMovieUser.id) {
            const reportButton = element("button", "text-action", "Report uploader");
            reportButton.type = "button";
            reportButton.addEventListener("click", () => openReportDialog(movie.uploaderId));
            details.append(reportButton);
        }
        card.append(player, details);
        movieList.append(card);
    }
}

function bytesToBase64(bytes) {
    let binary = "";
    const batchSize = 32768;
    for (let offset = 0; offset < bytes.length; offset += batchSize) {
        binary += String.fromCharCode(...bytes.subarray(offset, offset + batchSize));
    }
    return btoa(binary);
}

async function uploadMovie(file, values) {
    const start = await movieApi("/api/movies/upload/start", "POST", {
        title: values.title.trim(),
        description: values.description.trim(),
        fileName: file.name,
        contentType: file.type,
        fileSize: file.size,
        rightsConfirmed: values.rightsConfirmed === "on"
    });
    const chunkSize = start.chunkSize;
    uploadProgress.classList.remove("is-hidden");
    uploadProgress.value = 0;
    for (let chunkIndex = 0; chunkIndex < start.chunkCount; chunkIndex++) {
        const startByte = chunkIndex * chunkSize;
        const endByte = Math.min(startByte + chunkSize, file.size);
        const bytes = new Uint8Array(await file.slice(startByte, endByte).arrayBuffer());
        await movieApi("/api/movies/upload/chunk", "POST", {
            movieId: start.movieId,
            chunkIndex,
            contentBase64: bytesToBase64(bytes)
        });
        uploadProgress.value = Math.round((chunkIndex + 1) / start.chunkCount * 100);
        uploadStatus.textContent = `${formatBytes(endByte)} of ${formatBytes(file.size)}`;
    }
    await movieApi("/api/movies/upload/complete", "POST", { movieId: start.movieId });
}

function openReportDialog(userId) {
    const dialog = document.querySelector("#movie-report-dialog");
    dialog.elements.userId.value = userId;
    dialog.showModal();
}

document.querySelector("#refresh-movies").addEventListener("click", () => {
    loadMovies().catch((error) => showMovieMessage(error.message, true));
});

document.querySelector("#movie-upload-form").addEventListener("submit", async (event) => {
    event.preventDefault();
    const form = event.currentTarget;
    const file = form.elements.file.files[0];
    if (!file) return;
    if (file.size > 1024 * 1024 * 1024) {
        showMovieMessage("Movie files must be 1 GB or smaller.", true);
        return;
    }
    if (!["video/mp4", "video/webm"].includes(file.type)) {
        showMovieMessage("Choose an MP4 or WebM movie.", true);
        return;
    }
    uploadButton.disabled = true;
    uploadStatus.textContent = "Preparing upload…";
    try {
        const values = Object.fromEntries(new FormData(form));
        await uploadMovie(file, values);
        form.reset();
        uploadProgress.value = 0;
        uploadProgress.classList.add("is-hidden");
        uploadStatus.textContent = "Upload complete.";
        await loadMovies();
        showMovieMessage("Your movie is now in the library.");
    } catch (error) {
        uploadStatus.textContent = "Upload paused. Retry to start again.";
        showMovieMessage(error.message, true);
    } finally {
        uploadButton.disabled = false;
    }
});

document.querySelector("#movie-report-form").addEventListener("submit", async (event) => {
    event.preventDefault();
    const form = event.currentTarget;
    try {
        await movieApi("/api/reports", "POST", Object.fromEntries(new FormData(form)));
        form.reset();
        document.querySelector("#movie-report-dialog").close();
        showMovieMessage("Your report was sent to the admin.");
    } catch (error) {
        showMovieMessage(error.message, true);
    }
});

document.querySelector("#close-movie-report").addEventListener("click", () => document.querySelector("#movie-report-dialog").close());
document.querySelector("#movies-sign-out").addEventListener("click", async () => {
    try {
        await window.authService.logout();
        window.location.replace("/");
    } catch (error) {
        showMovieMessage(error.message, true);
    }
});

async function initializeMovies() {
    try {
        const result = await window.authService.currentUser();
        window.currentMovieUser = result.user;
        document.querySelector("#movies-user-name").textContent = result.user.name;
        await loadMovies();
    } catch (error) {
        if (error.message.toLowerCase().includes("banned")) {
            window.location.replace("/appeal.html");
            return;
        }
        if (error.message.includes("Please sign in")) {
            window.location.replace("/?reason=signin");
            return;
        }
        showMovieMessage(error.message, true);
    }
}

initializeMovies();
