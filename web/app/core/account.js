(() => {
  const {get, records, message, confirm} = window.Kaka;
  const pages = ['welcome', 'login', 'register'];
  const errors = {
    'auth-duplicate': 'An account already uses this email. Log in with that account.',
    'auth-credentials': 'That email or password is incorrect.',
    'auth-input': 'Check your account details and try again.',
    'auth-limit': 'This iPhone has reached its Kaka account limit.',
    'auth-needs-app': 'Open the Kaka iOS app to create an account or log in.',
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
    message(get(page + '-error'));
    if (reset) form.reset();
    for (const field of form.querySelectorAll('[aria-invalid]')) field.removeAttribute('aria-invalid');
  }

  function show(page, moveFocus) {
    const root = get('auth');
    const previous = root.dataset.page;
    if (previous !== page) {
      clearForm(previous, false);
      message(get('guest-error'));
      document.activeElement?.blur();
    }
    root.dataset.page = page;
    for (const id of pages) get(id).hidden = id !== page;
    if (previous !== page || moveFocus) {
      get('auth-scroll').scrollTop = 0;
      if (moveFocus) get(page + '-title').focus({preventScroll: true});
    }
  }

  function update(next) {
    session = next;
    const member = Boolean(next?.email);
    get('account-identity').textContent = next?.email ?? (next ? 'Browsing as a guest' : '');
    get('member-actions').hidden = !member;
    get('guest-actions').hidden = !next || member;
    message(get('account-error'));
    if (next) {
      clearForm('login', true);
      clearForm('register', true);
    }
  }

  function errorMessage(error) {
    const code = error?.message ?? String(error);
    const key = Object.keys(errors).find((item) => code.includes(item));
    return errors[key] ?? 'Kaka couldn’t finish that request. Please try again.';
  }

  async function change(control, loading, errorNode, command, fields = {}, target = 'stage', ask = null) {
    if (busy) return;
    busy = true;
    control.disabled = true;
    const label = control.textContent;
    message(errorNode);
    try {
      if (ask && !await confirm(ask)) {
        control.disabled = false;
        control.focus({preventScroll: true});
        return;
      }
      control.textContent = loading;
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
      await onChange(next, target);
    } catch (error) {
      message(errorNode, errorMessage(error));
    } finally {
      control.textContent = label;
      control.disabled = false;
      busy = false;
    }
  }

  function bindForm(page, loading) {
    const form = get(page + '-form');
    const submit = form.querySelector('[type="submit"]');
    const error = get(page + '-error');
    const password = form.elements.namedItem('password');
    const email = form.elements.namedItem('email');
    const name = form.elements.namedItem('name');
    const invalid = (field, text) => {
      field.setAttribute('aria-invalid', 'true');
      message(error, text);
      field.focus();
    };
    form.addEventListener('input', (event) => {
      event.target.removeAttribute('aria-invalid');
      message(error);
    });
    form.addEventListener('submit', (event) => {
      event.preventDefault();
      if (busy) return;
      const address = email.value.trim();
      if (name && !name.value.trim()) {
        invalid(name, 'Enter a stage name.');
      } else if (!/^[^@\s]+@[^@\s.]+(?:\.[^@\s.]+)+$/.test(address)) {
        invalid(email, 'Enter a valid email address.');
      } else if (!password.value.trim() || (name && password.value.length < 8)) {
        invalid(password, name ? 'Use at least 8 characters.' : 'Enter your password.');
      } else {
        document.activeElement?.blur();
        const fields = {email: address, password: password.value};
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
    get('continue-guest').addEventListener('click', (event) =>
      change(event.currentTarget, 'Opening rooms…', get('guest-error'), 'auth.guest'));

    for (const [id, page] of [['guest-register', 'register'], ['guest-login', 'login'], ['account-signout', 'welcome']]) {
      get(id).addEventListener('click', (event) => {
        if (!session) return;
        change(event.currentTarget, 'Leaving…', get('account-error'), 'auth.signOut', {session: session.token}, page);
      });
    }
    get('account-delete').addEventListener('click', (event) => {
      if (!session?.email) return;
      change(event.currentTarget, 'Deleting…', get('account-error'), 'auth.delete', {session: session.token}, 'welcome', {
        title: 'Delete your account?',
        description: 'This permanently removes your Kaka profile, drafts, saved rooms and follows for this account.',
        label: 'Delete account',
      });
    });
  }

  window.Kaka.account = {init, pages, show, update};
})();
