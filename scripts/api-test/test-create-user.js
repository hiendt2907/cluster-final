#!/usr/bin/env node

const https = require('https');
const http = require('http');

const API_HOST = process.env.API_HOST || 'localhost';
const API_PORT = process.env.API_PORT || 3000;
const USE_HTTPS = process.env.USE_HTTPS === 'true';

function makeRequest(options, data = null) {
    return new Promise((resolve, reject) => {
        const client = USE_HTTPS ? https : http;

        const req = client.request(options, (res) => {
            let body = '';
            res.on('data', (chunk) => {
                body += chunk;
            });
            res.on('end', () => {
                try {
                    const response = {
                        statusCode: res.statusCode,
                        headers: res.headers,
                        body: JSON.parse(body)
                    };
                    resolve(response);
                } catch (error) {
                    resolve({
                        statusCode: res.statusCode,
                        headers: res.headers,
                        body: body
                    });
                }
            });
        });

        req.on('error', (error) => {
            reject(error);
        });

        if (data) {
            req.write(JSON.stringify(data));
        }

        req.end();
    });
}

async function createUser(username, email, initialBalance = 1000) {
    console.log(`👤 Creating user: ${username} (${email})`);

    const options = {
        hostname: API_HOST,
        port: API_PORT,
        path: '/users',
        method: 'POST',
        headers: {
            'Content-Type': 'application/json',
        },
    };

    try {
        const response = await makeRequest(options, {
            username,
            email,
            initialBalance
        });

        if (response.statusCode === 201) {
            console.log('✅ User created successfully!');
            console.log('   ID:', response.body.user.id);
            console.log('   Username:', response.body.user.username);
            console.log('   Email:', response.body.user.email);
            console.log('   Balance:', response.body.user.balance);
            return response.body.user;
        } else {
            console.log('❌ Failed to create user:', response.body.error);
            return null;
        }
    } catch (error) {
        console.error('❌ Error creating user:', error.message);
        return null;
    }
}

async function testCreateUsers() {
    console.log('🧪 Testing Create User API');
    console.log('=' .repeat(50));

    // Test data
    const testUsers = [
        { username: 'alice', email: 'alice@example.com', balance: 5000 },
        { username: 'bob', email: 'bob@example.com', balance: 3000 },
        { username: 'charlie', email: 'charlie@example.com', balance: 2000 },
    ];

    for (const user of testUsers) {
        await createUser(user.username, user.email, user.balance);
        console.log(''); // Empty line for readability
    }

    // Test duplicate username
    console.log('🧪 Testing duplicate username...');
    await createUser('alice', 'alice2@example.com');
    console.log('');

    // Test missing fields
    console.log('🧪 Testing missing fields...');
    const options = {
        hostname: API_HOST,
        port: API_PORT,
        path: '/users',
        method: 'POST',
        headers: {
            'Content-Type': 'application/json',
        },
    };

    try {
        const response = await makeRequest(options, { username: 'test' }); // Missing email
        console.log('Response:', response.statusCode, response.body.error);
    } catch (error) {
        console.error('Error:', error.message);
    }
}

// Run if called directly
if (require.main === module) {
    testCreateUsers();
}

module.exports = { createUser, testCreateUsers };