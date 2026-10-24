const appealMessage = document.querySelector("#appeal-message");
const appealForm = document.querySelector("#appeal-form");

function showAppealMessage(text, isError = false) {
    appealMessage.textContent = text;
    appealMessage.classList.add("is-visible");
    appealMessage.classList.toggle("is-error", isError);
}

async function appealApi(path, method = "GET", body) {
    const options = { method };
    if (body !== undefined) options.body = JSON.stringify(body);
    return window.authService.request(path, options);
}

async function loadAppealStatus() {
    try {
        const result = await appealApi("/api/appeals/me");
        document.querySelector("#appeal-ban-reason").textContent = result.banReason ? `Reason shown for this restriction: ${result.banReason}` : "Your account is currently restricted.";
        if (!result.isBanned) {
            window.location.replace("/home.html");
            return;
        }
        if (result.appeal) {
            const status = document.querySelector("#appeal-status");
            status.classList.remove("is-hidden");
            status.textContent = result.appeal.status === "pending"
                ? "Your appeal is waiting for admin review."
                : `Your most recent appeal was ${result.appeal.status}. You may submit another appeal.`;
            if (result.appeal.status === "pending") appealForm.classList.add("is-hidden");
        }
    } catch (error) {
        if (error.message.includes("Please sign in")) {
            window.location.replace("/?reason=signin");
            return;
        }
        showAppealMessage(error.message, true);
    }
}

appealForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    const button = document.querySelector("#appeal-submit");
    button.disabled = true;
    try {
        await appealApi("/api/appeals", "POST", { reason: appealForm.elements.reason.value.trim() });
        appealForm.reset();
        await loadAppealStatus();
        showAppealMessage("Your appeal was sent to the admin.");
    } catch (error) {
        showAppealMessage(error.message, true);
    } finally {
        button.disabled = false;
    }
});

document.querySelector("#appeal-sign-out").addEventListener("click", async () => {
    try {
        await window.authService.logout();
        window.location.replace("/");
    } catch (error) {
        showAppealMessage(error.message, true);
    }
});

loadAppealStatus();
