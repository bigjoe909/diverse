const loginForm = document.querySelector("#login-form");
const signupForm = document.querySelector("#signup-form");
const formMessage = document.querySelector("#form-message");
const passwordInput = document.querySelector("#password");
const passwordToggle = document.querySelector("#password-toggle");
const cardHeading = document.querySelector("#login-heading");
const loginPrompt = document.querySelector("#login-prompt");
const signupPrompt = document.querySelector("#signup-prompt");

function showMessage(message, isError = false) {
    formMessage.textContent = message;
    formMessage.classList.add("is-visible");
    formMessage.classList.toggle("is-error", isError);
}

loginForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    try {
        const values = Object.fromEntries(new FormData(loginForm));
        const result = await window.authService.login(values);
        if (result.appealRequired) {
            window.location.assign("/appeal.html");
            return;
        }
        window.location.assign("/home.html");
    } catch (error) {
        showMessage(error.message, true);
    }
});

signupForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    const password = signupForm.elements.password.value;
    const confirmation = signupForm.elements["confirm-password"].value;
    if (password !== confirmation) {
        signupForm.elements["confirm-password"].setCustomValidity("Passwords do not match.");
        signupForm.reportValidity();
        signupForm.elements["confirm-password"].setCustomValidity("");
        return;
    }

    try {
        await window.authService.register(Object.fromEntries(new FormData(signupForm)));
        signupForm.reset();
        showMessage("Your account was created and saved. You can now sign in.");
    } catch (error) {
        showMessage(error.message, true);
    }
});

passwordToggle.addEventListener("click", () => {
    const isPasswordVisible = passwordInput.type === "text";
    passwordInput.type = isPasswordVisible ? "password" : "text";
    passwordToggle.setAttribute("aria-pressed", String(!isPasswordVisible));
    passwordToggle.setAttribute("aria-label", isPasswordVisible ? "Show password" : "Hide password");
});

document.querySelector("#show-signup").addEventListener("click", (event) => {
    event.preventDefault();
    loginForm.classList.add("is-hidden");
    signupForm.classList.remove("is-hidden");
    loginPrompt.classList.add("is-hidden");
    signupPrompt.classList.remove("is-hidden");
    cardHeading.innerHTML = '<span class="eyebrow">JOIN THE UNIVERSE</span><h1 id="login-title">Create your account</h1><p>Your next adventure starts here.</p>';
    formMessage.classList.remove("is-visible");
    document.querySelector("#signup-name").focus();
});

document.querySelector("#show-login").addEventListener("click", (event) => {
    event.preventDefault();
    signupForm.classList.add("is-hidden");
    loginForm.classList.remove("is-hidden");
    signupPrompt.classList.add("is-hidden");
    loginPrompt.classList.remove("is-hidden");
    cardHeading.innerHTML = '<span class="eyebrow">WELCOME BACK</span><h1 id="login-title">Sign in to your universe</h1><p>Pick up right where you left off.</p>';
    formMessage.classList.remove("is-visible");
    document.querySelector("#email").focus();
});

document.querySelector("[data-notice]").addEventListener("click", (event) => {
    event.preventDefault();
    showMessage(event.currentTarget.dataset.notice, true);
});

if (new URLSearchParams(window.location.search).get("reason") === "signin") {
    showMessage("Please sign in to access your homepage.", true);
}
