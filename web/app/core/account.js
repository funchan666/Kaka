(() => {
  const {get, records, service, message, confirm} = window.Kaka;
  const pages = ['welcome', 'login', 'register'];
  const errors = {
    'auth-duplicate': 'An account already uses this email. Log in to continue.',
    'auth-input': 'Check your account details and try again.',
    'auth-needs-app': 'Open the iOS app to create an account or log in.',
    'auth-rejected': 'That email or password was rejected. Check your details and try again.',
  };
  let busy = false;
  let session;
  let onChange;

  function showPassword(control, visible) {
    get(control.dataset.password).type = visible ? 'text' : 'password';
    control.textContent = visible ? 'Hide' : 'Show';
    control.setAttribute('aria-label', visible ? 'Hide password' : 'Show password');
  }

  function clearForm(page, reset) {
    const form = get(page + '-form');
    if (!form) return;
    const toggle = form.querySelector('[data-password]');
    const password = get(toggle.dataset.password);
    showPassword(toggle, false);
    password.value = '';
    form.elements.namedItem('consent').checked = false;
    message(get(page + '-error'));
    message(get(page + '-consent-error'));
    if (reset) form.reset();
    for (const field of form.querySelectorAll('[aria-invalid]')) field.removeAttribute('aria-invalid');
  }

  function show(page, moveFocus) {
    const root = get('auth');
    const previous = root.dataset.page;
    if (previous !== page) {
      const lastEmail = get(previous + '-form')?.elements.namedItem('email').value.trim();
      const nextEmail = get(page + '-form')?.elements.namedItem('email');
      if (lastEmail && nextEmail && !nextEmail.value) nextEmail.value = lastEmail;
      clearForm(previous, false);
      document.activeElement?.blur();
    }
    root.dataset.page = page;
    get('auth-back').hidden = page === 'welcome';
    for (const id of pages) get(id).hidden = id !== page;
    if (previous !== page || moveFocus) {
      get('auth-scroll').scrollTop = 0;
      if (moveFocus) get(page + '-title').focus({preventScroll: true});
    }
  }

  function update(next) {
    session = next;
    get('account-identity').textContent = next?.email ?? '';
    message(get('account-error'));
    if (next) {
      clearForm('login', true);
      clearForm('register', true);
    }
  }

  function errorMessage(error) {
    const code = error?.message ?? String(error);
    const key = Object.keys(errors).find((item) => code.includes(item));
    return errors[key] ?? service.errorMessage(error);
  }

  async function change(control, loading, errorNode, command, fields = {}, target = 'stage', ask = null) {
    if (busy) return;
    busy = true;
    control.disabled = true;
    const caption = control.querySelector('.control-label') ?? control;
    const label = caption.textContent;
    const loginLoading = command === 'auth.login' ? get('login-loading') : null;
    const authScroll = loginLoading && get('auth-scroll');
    let loginLoadingUntil = 0;
    let failure;
    message(errorNode);
    try {
      if (ask && !await confirm(ask)) {
        control.disabled = false;
        control.focus({preventScroll: true});
        return;
      }
      caption.textContent = loading;
      if (loginLoading) {
        authScroll.setAttribute('aria-busy', 'true');
        loginLoading.hidden = false;
        get('login-loading-status').focus({preventScroll: true});
        // Keep the loading state legible even when the service responds quickly.
        loginLoadingUntil = performance.now() + 480;
      }
      const leaving = Boolean(fields.session);
      if (leaving) await records.settled();
      let next;
      try {
        next = await records.call(command, fields);
      } catch (error) {
        if (!/bridge-timeout|bridge-response|session-changed/.test(error?.message ?? error)) throw error;
        next = await records.call('auth.session');
        if (leaving ? next?.token === fields.session : !next) throw error;
      }
      const remaining = loginLoadingUntil - performance.now();
      if (remaining > 0) await new Promise((resolve) => setTimeout(resolve, remaining));
      await onChange(next, target);
    } catch (error) {
      failure = errorMessage(error);
    } finally {
      if (loginLoading) {
        loginLoading.hidden = true;
        authScroll.removeAttribute('aria-busy');
      }
      caption.textContent = label;
      control.disabled = false;
      busy = false;
      if (failure) {
        message(errorNode, failure);
        const disclosure = errorNode.closest('details');
        if (disclosure) disclosure.open = true;
        if (loginLoading && !control.closest('[hidden]')) control.focus({preventScroll: true});
      }
    }
  }

  function bindForm(page, loading) {
    const form = get(page + '-form');
    const submit = form.querySelector('[type="submit"]');
    const error = get(page + '-error');
    const consentError = get(page + '-consent-error');
    const password = form.elements.namedItem('password');
    const email = form.elements.namedItem('email');
    const name = form.elements.namedItem('name');
    const consent = form.elements.namedItem('consent');
    const invalid = (field, text) => {
      field.setAttribute('aria-invalid', 'true');
      message(field === consent ? consentError : error, text);
      field.focus();
    };
    form.addEventListener('input', (event) => {
      event.target.removeAttribute('aria-invalid');
      message(event.target === consent ? consentError : error);
    });
    form.addEventListener('submit', (event) => {
      event.preventDefault();
      if (busy) return;
      const address = email.value.trim();
      if (!consent.checked) {
        invalid(consent, 'Agree to the Terms of Use and Privacy Policy to continue.');
      } else if (name && !name.value.trim()) {
        invalid(name, 'Enter a stage name.');
      } else if (!/^[^@\s]+@[^@\s.]+(?:\.[^@\s.]+)+$/.test(address)) {
        invalid(email, 'Enter a valid email address.');
      } else if (!password.value.trim() || (name && password.value.length < 8)) {
        invalid(password, name ? 'Use at least 8 characters.' : 'Enter your password.');
      } else {
        document.activeElement?.blur();
        const fields = {email: address, password: password.value, acceptedPolicies: consent.checked};
        if (name) fields.name = name.value.trim();
        change(submit, loading, error, 'auth.' + page, fields);
      }
    });
  }

  function init(handleChange) {
    onChange = handleChange;
    document.querySelectorAll('[data-password]').forEach((toggle) => {
      showPassword(toggle, false);
      toggle.addEventListener('click', () => showPassword(toggle, get(toggle.dataset.password).type === 'password'));
    });
    bindForm('login', 'Logging in…');
    bindForm('register', 'Creating account…');
    get('account-signout').addEventListener('click', (event) => {
      if (!session) return;
      change(event.currentTarget, 'Logging out…', get('account-error'), 'auth.signOut', {session: session.token}, 'welcome');
    });
    get('account-delete').addEventListener('click', (event) => {
      if (!session) return;
      change(event.currentTarget, 'Deleting…', get('account-error'), 'auth.delete', {session: session.token}, 'welcome', {
        title: 'Delete your account?',
        description: 'This permanently removes your profile, drafts, saved rooms and follows for this account.',
        label: 'Delete account',
      });
    });
  }

  window.Kaka.account = {init, pages, show, update};
})();
