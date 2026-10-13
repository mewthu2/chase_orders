(() => {
  function initializeProfilePhotos() {
    document.querySelectorAll('[data-profile-photo]').forEach((editor) => {
      if (editor.dataset.initialized) return;
      editor.dataset.initialized = 'true';

      const input = editor.querySelector('[data-photo-input]');
      const preview = editor.querySelector('[data-photo-preview]');
      const placeholder = editor.querySelector('[data-photo-placeholder]');
      const remove = editor.querySelector('[data-photo-remove]');
      const error = editor.querySelector('[data-photo-error]');
      const originalSource = preview.getAttribute('src');
      let previewUrl;
      let selection = 0;

      function releasePreview() {
        if (previewUrl) URL.revokeObjectURL(previewUrl);
        previewUrl = null;
      }

      function showPreview(source) {
        if (source) preview.src = source;
        else preview.removeAttribute('src');
        preview.hidden = !source;
        placeholder.hidden = !!source;
      }

      function showError(message) {
        input.setCustomValidity(message);
        input.setAttribute('aria-invalid', String(!!message));
        error.textContent = message;
      }

      input.addEventListener('change', () => {
        const file = input.files[0];
        const currentSelection = ++selection;
        releasePreview();
        showError('');
        showPreview(remove?.checked ? null : originalSource);
        if (!file) return;

        if (!['image/jpeg', 'image/png', 'image/webp'].includes(file.type)) {
          showError('Escolha uma imagem JPG, PNG ou WEBP.');
          return;
        }
        if (file.size > Number(editor.dataset.maxSize)) {
          showError('A foto deve ter no máximo 5 MB.');
          return;
        }

        previewUrl = URL.createObjectURL(file);
        const image = new Image();
        image.onload = () => {
          if (currentSelection !== selection) return;
          if (remove) remove.checked = false;
          showPreview(previewUrl);
        };
        image.onerror = () => {
          if (currentSelection !== selection) return;
          releasePreview();
          showError('Não foi possível abrir essa imagem. Escolha outra foto.');
        };
        image.src = previewUrl;
      });

      remove?.addEventListener('change', () => {
        ++selection;
        input.value = '';
        releasePreview();
        showError('');
        showPreview(remove.checked ? null : originalSource);
      });

      input.form.addEventListener('submit', (event) => {
        if (!input.validity.valid) {
          event.preventDefault();
          input.reportValidity();
        }
      });
      window.addEventListener('pagehide', releasePreview, { once: true });
    });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', initializeProfilePhotos);
  } else {
    initializeProfilePhotos();
  }
  document.addEventListener('turbo:load', initializeProfilePhotos);
})();
