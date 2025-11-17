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

async function viewProfile(userId) {
    console.log(`👤 Viewing profile for user ID: ${userId}`);

    const options = {
        hostname: API_HOST,
        port: API_PORT,
        path: `/profile/${userId}`,
        method: 'GET',
        headers: {
            'Content-Type': 'application/json',
        },
    };

    try {
        const response = await makeRequest(options);

        if (response.statusCode === 200) {
            const profile = response.body;
            console.log('✅ Profile retrieved successfully!');
            console.log('👤 User Info:');
            console.log('   ID:', profile.user.id);
            console.log('   Username:', profile.user.username);
            console.log('   Email:', profile.user.email);
            console.log('   Balance: $' + profile.user.balance);
            console.log('   Created:', new Date(profile.user.created_at).toLocaleString());

            console.log('📊 Portfolio Stats:');
            console.log('   Total Orders:', profile.portfolio.totalOrders);
            console.log('   Pending Orders:', profile.portfolio.pendingOrders);
            console.log('   Filled Orders:', profile.portfolio.filledOrders);
            console.log('   Total Trades:', profile.portfolio.totalTrades);

            if (profile.recentOrders.length > 0) {
                console.log('📋 Recent Orders:');
                profile.recentOrders.slice(0, 3).forEach((order, index) => {
                    console.log(`   ${index + 1}. ${order.type.toUpperCase()} ${order.quantity} ${order.symbol} @ $${order.price} (${order.status})`);
                });
            }

            if (profile.recentTrades.length > 0) {
                console.log('💼 Recent Trades:');
                profile.recentTrades.slice(0, 3).forEach((trade, index) => {
                    const role = trade.is_buyer ? 'BOUGHT' : 'SOLD';
                    console.log(`   ${index + 1}. ${role} ${trade.quantity} ${trade.buy_symbol || trade.sell_symbol} @ $${trade.price}`);
                });
            }

            return profile;
        } else {
            console.log('❌ Failed to retrieve profile:', response.body.error);
            return null;
        }
    } catch (error) {
        console.error('❌ Error retrieving profile:', error.message);
        return null;
    }
}

async function testViewProfile() {
    console.log('🧪 Testing View Profile API');
    console.log('=' .repeat(50));

    // First, create some test data
    console.log('📝 Setting up test data...');
    const createUser = require('./test-create-user').createUser;
    const createTransaction = require('./test-create-transaction').createTransaction;

    const user1 = await createUser('profile_test_1', 'profile1@test.com', 10000);
    const user2 = await createUser('profile_test_2', 'profile2@test.com', 5000);

    if (!user1 || !user2) {
        console.log('❌ Failed to create test users');
        return;
    }

    // Create some orders
    await createTransaction(user1.id, 'BTC', 'buy', 1, 45000);
    await createTransaction(user1.id, 'ETH', 'buy', 2, 3000);
    await createTransaction(user1.id, 'USDT', 'sell', 1000, 1);
    await createTransaction(user2.id, 'BTC', 'sell', 0.5, 46000);

    console.log('');

    // Test viewing profiles
    console.log('🧪 Testing profile views...');
    await viewProfile(user1.id);
    console.log('');
    await viewProfile(user2.id);
    console.log('');

    // Test invalid user ID
    console.log('🧪 Testing invalid user ID...');
    await viewProfile(99999);
    console.log('');

    // Test non-numeric user ID
    console.log('🧪 Testing non-numeric user ID...');
    const options = {
        hostname: API_HOST,
        port: API_PORT,
        path: '/profile/invalid',
        method: 'GET',
        headers: {
            'Content-Type': 'application/json',
        },
    };

    try {
        const response = await makeRequest(options);
        console.log('Response:', response.statusCode, response.body.error);
    } catch (error) {
        console.error('Error:', error.message);
    }
    console.log('');

    // Test getting all users (for reference)
    console.log('👥 All users in system:');
    const allUsersOptions = {
        hostname: API_HOST,
        port: API_PORT,
        path: '/profile',
        method: 'GET',
        headers: {
            'Content-Type': 'application/json',
        },
    };

    try {
        const response = await makeRequest(allUsersOptions);
        if (response.statusCode === 200) {
            response.body.users.forEach(user => {
                console.log(`   ${user.id}: ${user.username} (${user.email}) - $${user.balance}`);
            });
        }
    } catch (error) {
        console.error('Error:', error.message);
    }
}

// Run if called directly
if (require.main === module) {
    testViewProfile();
}

module.exports = { viewProfile, testViewProfile };