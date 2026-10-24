(function () {
    const appOrigin = "http://127.0.0.1:8765";
    const isAppOrigin = window.location.origin === appOrigin;

    if (!isAppOrigin) {
        const destination = window.location.protocol === "file:"
            ? `${appOrigin}/`
            : `${appOrigin}${window.location.pathname}${window.location.search}${window.location.hash}`;
        window.location.replace(destination);
    }

    async function request(path, options = {}) {
        if (!isAppOrigin) {
            throw new Error("Opening the app on its local database server…");
        }

        let response;
        try {
            response = await fetch(path, {
                ...options,
                credentials: "same-origin",
                headers: {
                    ...(options.body ? { "Content-Type": "application/json" } : {}),
                    ...options.headers
                }
            });
        } catch (error) {
            if (error instanceof TypeError) {
                throw new Error("Unable to reach the local account database. Double-click start-local.bat, keep its server window open, and use the address it opens.");
            }
            throw error;
        }

        const responseText = await response.text();
        let result;
        try {
            result = responseText ? JSON.parse(responseText) : {};
        } catch {
            throw new Error(`The sign-in service returned an invalid response (HTTP ${response.status}). Restart it with start-local.bat and try again.`);
        }

        if (!response.ok) {
            throw new Error(result.error || `The request failed (HTTP ${response.status}).`);
        }
        return result;
    }

    function post(path, values) {
        return request(path, {
            method: "POST",
            body: JSON.stringify(values)
        });
    }

    window.authService = Object.freeze({
        request,
        login: (credentials) => post("/api/login", credentials),
        register: (details) => post("/api/register", details),
        currentUser: () => request("/api/auth/me"),
        logout: () => post("/api/logout", {})
    });
})();
