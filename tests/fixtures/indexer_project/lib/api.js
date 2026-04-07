/**
 * API route handlers for the sample project.
 */

const { validateEmail } = require('./utils');

function handleCreateUser(req) {
    if (!validateEmail(req.body.email)) {
        return { status: 400, error: 'Invalid email' };
    }
    return { status: 201, data: req.body };
}

function handleGetUser(userId) {
    return { status: 200, data: { id: userId } };
}

module.exports = { handleCreateUser, handleGetUser };
