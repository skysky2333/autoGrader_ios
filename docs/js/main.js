/* ============================================================
   HGrader + CanvasConnect Docs — Interactions
   ============================================================ */

(function () {
  'use strict';

  /* --- Mobile Nav Toggle ------------------------------------ */
  const mobileToggle = document.querySelector('.mobile-toggle');
  const navLinks = document.querySelector('.nav-links');

  if (mobileToggle && navLinks) {
    mobileToggle.addEventListener('click', () => {
      navLinks.classList.toggle('open');
      const expanded = navLinks.classList.contains('open');
      mobileToggle.setAttribute('aria-expanded', expanded);
    });
  }

  /* --- Dropdown Menus --------------------------------------- */
  document.querySelectorAll('.nav-dropdown > .nav-link').forEach(trigger => {
    trigger.addEventListener('click', (e) => {
      e.preventDefault();
      const dropdown = trigger.parentElement;
      const wasOpen = dropdown.classList.contains('open');

      document.querySelectorAll('.nav-dropdown.open').forEach(d => d.classList.remove('open'));

      if (!wasOpen) dropdown.classList.add('open');
    });
  });

  document.addEventListener('click', (e) => {
    if (!e.target.closest('.nav-dropdown')) {
      document.querySelectorAll('.nav-dropdown.open').forEach(d => d.classList.remove('open'));
    }
  });

  /* --- Sidebar Toggle (mobile docs) ------------------------- */
  const sidebarToggle = document.querySelector('.sidebar-toggle');
  const sidebar = document.querySelector('.docs-sidebar');
  const overlay = document.querySelector('.sidebar-overlay');

  function closeSidebar() {
    if (sidebar) sidebar.classList.remove('open');
    if (overlay) overlay.classList.remove('open');
  }

  if (sidebarToggle && sidebar) {
    sidebarToggle.addEventListener('click', () => {
      sidebar.classList.toggle('open');
      if (overlay) overlay.classList.toggle('open');
    });
  }

  if (overlay) {
    overlay.addEventListener('click', closeSidebar);
  }

  /* --- Active Sidebar Link ---------------------------------- */
  const currentPath = window.location.pathname.replace(/\/$/, '/index.html');
  document.querySelectorAll('.sidebar-link').forEach(link => {
    const href = link.getAttribute('href');
    if (href && currentPath.endsWith(href.replace(/^\.\//, '').replace(/^\.\.\//, ''))) {
      link.classList.add('active');
    }
  });

  /* --- Smooth Scroll for Anchor Links ----------------------- */
  document.querySelectorAll('a[href^="#"]').forEach(anchor => {
    anchor.addEventListener('click', (e) => {
      const target = document.querySelector(anchor.getAttribute('href'));
      if (target) {
        e.preventDefault();
        target.scrollIntoView({ behavior: 'smooth', block: 'start' });
        history.pushState(null, '', anchor.getAttribute('href'));
      }
    });
  });

  /* --- Escape Key Closes Menus ------------------------------ */
  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') {
      document.querySelectorAll('.nav-dropdown.open').forEach(d => d.classList.remove('open'));
      if (navLinks) navLinks.classList.remove('open');
      closeSidebar();
    }
  });
})();
