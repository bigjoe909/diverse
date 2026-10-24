const loginForm = document.querySelector("#admin-login-form");
const dashboard = document.querySelector("#dashboard");
const message = document.querySelector("#admin-message");
const title = document.querySelector("#admin-title");
const subtitle = document.querySelector("#admin-subtitle");
let dashboardRefreshTimer = null;

async function request(path, method = "GET", values) {
    const options = { method };
    if (values) {
        options.body = JSON.stringify(values);
    }
    return window.authService.request(path, options);
}

function showMessage(text, isError = false) {
    message.textContent = text;
    message.classList.add("is-visible");
    message.classList.toggle("is-error", isError);
}

function showView(view) {
    document.body.classList.toggle("is-admin-dashboard", view === "dashboard");
    loginForm.classList.toggle("is-hidden", view !== "login");
    dashboard.classList.toggle("is-hidden", view !== "dashboard");
    message.classList.remove("is-visible");
}

function cell(text) {
    const node = document.createElement("td");
    node.textContent = text;
    return node;
}

function actionButton(label, callback) {
    const button = document.createElement("button");
    button.className = "secondary-button admin-action";
    button.type = "button";
    button.textContent = label;
    button.addEventListener("click", callback);
    return button;
}

async function loadAccounts() {
    const search = document.querySelector("#account-search").value.trim();
    const result = await request(`/api/admin/accounts?q=${encodeURIComponent(search)}`);
    const rows = document.querySelector("#account-list");
    rows.replaceChildren();
    for (const account of result.accounts) {
        const row = document.createElement("tr");
        row.append(cell(account.name), cell(account.email), cell(new Date(account.createdAt).toLocaleString()));
        row.append(cell(account.isBanned ? "Banned" : account.isOnline ? "Online" : "Offline"));
        const actionCell = document.createElement("td");
        actionCell.append(actionButton(account.isBanned ? "Unban" : "Ban", async () => {
            if (account.isBanned) {
                try {
                    await request("/api/admin/users/unban", "POST", { userId: account.id });
                    await Promise.all([loadAccounts(), loadAppeals()]);
                    showMessage(`${account.name} was unbanned.`);
                } catch (error) {
                    showMessage(error.message, true);
                }
            } else {
                const dialog = document.querySelector("#ban-dialog");
                dialog.elements.userId.value = account.id;
                dialog.querySelector("h2").textContent = `Ban ${account.name}`;
                dialog.showModal();
            }
        }));
        row.append(actionCell);
        rows.append(row);
    }
    document.querySelector("#account-count").textContent = String(result.accounts.length);
    document.querySelector("#online-count").textContent = String(result.onlineUsers);
    document.querySelector("#empty-state").classList.toggle("is-hidden", result.accounts.length !== 0);
}

async function loadReports() {
    const result = await request("/api/admin/reports");
    const list = document.querySelector("#report-list");
    list.replaceChildren();
    if (!result.reports.length) {
        list.append(Object.assign(document.createElement("p"), { className: "admin-inbox-empty", textContent: "No user reports." }));
        return;
    }
    for (const report of result.reports) {
        const item = document.createElement("article");
        item.className = "admin-inbox-item";
        const heading = document.createElement("div");
        heading.className = "admin-inbox-item-heading";
        const title = document.createElement("strong");
        title.textContent = `${report.category} · ${report.reportedName}`;
        const status = document.createElement("span");
        status.className = `admin-status ${report.status}`;
        status.textContent = report.status;
        heading.append(title, status);
        const details = document.createElement("p");
        details.textContent = report.details;
        const meta = document.createElement("span");
        meta.className = "item-meta";
        meta.textContent = `Reported by ${report.reporterName} (${report.reporterEmail}) · ${new Date(report.createdAt).toLocaleString()}`;
        item.append(heading, details, meta);
        if (report.status === "open") {
            item.append(actionButton("Resolve report", async () => {
                try {
                    await request("/api/admin/reports/resolve", "POST", { reportId: report.id });
                    await loadReports();
                    showMessage("Report resolved.");
                } catch (error) {
                    showMessage(error.message, true);
                }
            }));
        }
        list.append(item);
    }
}

async function loadAppeals() {
    const result = await request("/api/admin/appeals");
    const list = document.querySelector("#appeal-list");
    list.replaceChildren();
    if (!result.appeals.length) {
        list.append(Object.assign(document.createElement("p"), { className: "admin-inbox-empty", textContent: "No unban appeals." }));
        return;
    }
    for (const appeal of result.appeals) {
        const item = document.createElement("article");
        item.className = "admin-inbox-item";
        const heading = document.createElement("div");
        heading.className = "admin-inbox-item-heading";
        const title = document.createElement("strong");
        title.textContent = `${appeal.name} · ${appeal.email}`;
        const status = document.createElement("span");
        status.className = `admin-status ${appeal.status}`;
        status.textContent = appeal.status;
        heading.append(title, status);
        const banReason = document.createElement("span");
        banReason.className = "item-meta";
        banReason.textContent = appeal.banReason ? `Ban reason: ${appeal.banReason}` : "No ban reason recorded.";
        const reason = document.createElement("p");
        reason.textContent = appeal.reason;
        item.append(heading, banReason, reason);
        if (appeal.status === "pending") {
            const actions = document.createElement("div");
            actions.className = "admin-inbox-actions";
            for (const [label, decision] of [["Approve and unban", "approve"], ["Deny appeal", "deny"]]) {
                actions.append(actionButton(label, async () => {
                    try {
                        await request("/api/admin/appeals/review", "POST", { appealId: appeal.id, decision });
                        await Promise.all([loadAccounts(), loadAppeals()]);
                        showMessage(decision === "approve" ? `${appeal.name} was unbanned.` : "Appeal denied.");
                    } catch (error) {
                        showMessage(error.message, true);
                    }
                }));
            }
            item.append(actions);
        }
        list.append(item);
    }
}

async function refreshModerationQueues() {
    try {
        await Promise.all([loadAccounts(), loadReports(), loadAppeals()]);
    } catch (error) {
        showMessage(error.message, true);
    }
}

async function initialize() {
    try {
        const status = await request("/api/admin/status");
        document.querySelector("#admin-email").value = status.ownerEmail;
        title.textContent = "DI-VERSE dashboard";
        subtitle.textContent = "Sign in to manage locally stored accounts.";
        if (status.authenticated) {
            showView("dashboard");
            await refreshModerationQueues();
            dashboardRefreshTimer = window.setInterval(() => refreshModerationQueues(), 30000);
        } else {
            showView("login");
        }
    } catch (error) {
        showMessage(error.message, true);
    }
}

loginForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    try {
        await request("/api/admin/login", "POST", Object.fromEntries(new FormData(loginForm)));
        showView("dashboard");
        await loadAccounts();
    } catch (error) {
        showMessage(error.message, true);
    }
});

document.querySelector("#refresh-accounts").addEventListener("click", async () => {
    try {
        await loadAccounts();
        showMessage("Account list refreshed.");
    } catch (error) {
        showMessage(error.message, true);
    }
});

document.querySelector("#account-search-form").addEventListener("submit", async (event) => {
    event.preventDefault();
    try {
        await loadAccounts();
    } catch (error) {
        showMessage(error.message, true);
    }
});

document.querySelector("#refresh-reports").addEventListener("click", () => loadReports().catch((error) => showMessage(error.message, true)));
document.querySelector("#refresh-appeals").addEventListener("click", () => loadAppeals().catch((error) => showMessage(error.message, true)));

document.querySelector("#ban-form").addEventListener("submit", async (event) => {
    event.preventDefault();
    const form = event.currentTarget;
    try {
        await request("/api/admin/users/ban", "POST", Object.fromEntries(new FormData(form)));
        document.querySelector("#ban-dialog").close();
        form.reset();
        await loadAccounts();
        showMessage("Account banned.");
    } catch (error) {
        showMessage(error.message, true);
    }
});

document.querySelector("#close-ban-dialog").addEventListener("click", () => document.querySelector("#ban-dialog").close());

document.querySelector("#admin-logout").addEventListener("click", async () => {
    try {
    window.clearInterval(dashboardRefreshTimer);
        await request("/api/admin/logout", "POST", {});
        showView("login");
        showMessage("You have been signed out.");
    } catch (error) {
        showMessage(error.message, true);
    }
});

initialize();
