const homeMessage = document.querySelector("#home-message");
const signOutButton = document.querySelector("#sign-out");

async function loadHomepage() {
    try {
        const result = await window.authService.currentUser();
        document.querySelector("#welcome-name").textContent = result.user.name;
        document.querySelector("#account-email").textContent = result.user.email;
        document.querySelector("#account-created").textContent = new Date(result.user.createdAt).toLocaleDateString();
        homeMessage.classList.remove("is-visible", "is-error");
        signOutButton.disabled = false;
    } catch (error) {
        if (error.message.toLowerCase().includes("banned")) {
            window.location.replace("/appeal.html");
            return;
        }
        if (error.message.includes("Please sign in")) {
            window.location.replace("/?reason=signin");
            return;
        }
        homeMessage.textContent = error.message;
        homeMessage.classList.add("is-visible", "is-error");
    }
}

signOutButton.addEventListener("click", async () => {
    signOutButton.disabled = true;
    try {
        await window.authService.logout();
        window.location.replace("/");
    } catch (error) {
        homeMessage.textContent = error.message;
        homeMessage.classList.add("is-visible", "is-error");
        signOutButton.disabled = false;
    }
});

loadHomepage();
