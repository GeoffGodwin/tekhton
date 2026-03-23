/**
 * Utility functions for the sample project.
 */

function formatDate(date) {
    return date.toISOString().split('T')[0];
}

function validateEmail(email) {
    return email.includes('@') && email.includes('.');
}

function capitalize(str) {
    return str.charAt(0).toUpperCase() + str.slice(1);
}

module.exports = { formatDate, validateEmail, capitalize };
