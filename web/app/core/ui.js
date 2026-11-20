(() => {
  const get = (id) => document.getElementById(id);

  function element(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  }

  function button(label, action, className = 'button secondary') {
    const control = element('button', className, label);
    control.type = 'button';
    control.addEventListener('click', action);
    return control;
  }

  function link(label, route, className = 'button secondary') {
    const anchor = element('a', className, label);
    anchor.href = '#' + route;
    return anchor;
  }

  function image(file, className, alt = '') {
    const node = element('img', className);
    node.src = 'assets/images/' + file;
    node.alt = alt;
    return node;
  }

  function actionIcon(control, file, iconOnlyLabel) {
    const icon = image(file, 'action-icon');
    icon.width = 24;
    icon.height = 24;
    if (iconOnlyLabel) {
      control.classList.add('icon-button');
      control.setAttribute('aria-label', iconOnlyLabel);
      control.replaceChildren(icon);
    } else {
      control.prepend(icon);
    }
    return control;
  }

  let noticeTimer;
  function notify(text) {
    const toast = get('toast');
    clearTimeout(noticeTimer);
    toast.textContent = text;
    noticeTimer = setTimeout(() => { toast.textContent = ''; }, 3200);
  }

  function message(node, text = '') {
    node.textContent = text;
    node.hidden = !text;
  }

  async function pending(control, action, onError = (error) => notify(error.message)) {
    if (control.disabled) return;
    control.disabled = true;
    try {
      await action();
    } catch (error) {
      onError(error);
    } finally {
      control.disabled = false;
    }
  }

  function uuid() {
    const bytes = crypto.getRandomValues(new Uint8Array(16));
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    const hex = Array.from(bytes, (part) => part.toString(16).padStart(2, '0')).join('');
    return [hex.slice(0, 8), hex.slice(8, 12), hex.slice(12, 16), hex.slice(16, 20), hex.slice(20)].join('-');
  }

  let dismissal;
  function confirm({title, description, label}) {
    if (dismissal) return Promise.resolve(false);
    const overlay = get('decision-overlay');
    const cancel = get('decision-cancel');
    const proceed = get('decision-confirm');
    const previous = document.activeElement;
    previous?.blur();
    get('decision-title').textContent = title;
    get('decision-text').textContent = description;
    proceed.textContent = label;
    overlay.hidden = false;
    get('app').setAttribute('aria-hidden', 'true');
    cancel.focus();

    return new Promise((resolve) => {
      dismissal = (accepted) => {
        dismissal = undefined;
        overlay.hidden = true;
        get('app').removeAttribute('aria-hidden');
        cancel.onclick = null;
        proceed.onclick = null;
        overlay.onkeydown = null;
        if (previous?.isConnected) previous.focus({preventScroll: true});
        resolve(accepted);
      };
      cancel.onclick = () => dismissal(false);
      proceed.onclick = () => dismissal(true);
      overlay.onkeydown = (event) => {
        if (event.key === 'Escape') {
          event.preventDefault();
          dismissal(false);
        } else if (event.key === 'Tab') {
          event.preventDefault();
          (document.activeElement === cancel ? proceed : cancel).focus();
        }
      };
    });
  }

  window.Kaka = {get, element, button, link, image, actionIcon, notify, message, pending, uuid, confirm};
})();
