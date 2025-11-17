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

async function createTransaction(userId, symbol, type, quantity, price) {
    console.log(`💰 Creating ${type} order: ${quantity} ${symbol} @ $${price} for user ${userId}`);

    const options = {
        hostname: API_HOST,
        port: API_PORT,
        path: '/transactions',
        method: 'POST',
        headers: {
            'Content-Type': 'application/json',
        },
    };

    try {
        const response = await makeRequest(options, {
            userId,
            symbol,
            type,
            quantity,
            price
        });

        if (response.statusCode === 201) {
            console.log('✅ Order created successfully!');
            console.log('   Order ID:', response.body.order.id);
            console.log('   Type:', response.body.order.type);
            console.log('   Symbol:', response.body.order.symbol);
            console.log('   Quantity:', response.body.order.quantity);
            console.log('   Price:', response.body.order.price);
            console.log('   Status:', response.body.order.status);
            return response.body.order;
        } else {
            console.log('❌ Failed to create order:', response.body.error);
            if (response.body.required && response.body.available) {
                console.log(`   Required: $${response.body.required}, Available: $${response.body.available}`);
            }
            return null;
        }
    } catch (error) {
        console.error('❌ Error creating order:', error.message);
        return null;
    }
}

async function testCreateTransactions() {
    console.log('🧪 Testing Create Transaction API');
    console.log('=' .repeat(50));

    // First, create some test users
    console.log('👥 Creating test users...');
    const createUser = require('./test-create-user').createUser;

    const user1 = await createUser('trader_test_1', 'trader1@test.com', 10000);
    const user2 = await createUser('trader_test_2', 'trader2@test.com', 5000);

    if (!user1 || !user2) {
        console.log('❌ Failed to create test users');
        return;
    }

    console.log('');

    // Test valid buy orders
    console.log('🧪 Testing valid buy orders...');
    await createTransaction(user1.id, 'BTC', 'buy', 1, 45000);
    await createTransaction(user1.id, 'ETH', 'buy', 5, 3000);
    await createTransaction(user2.id, 'BTC', 'buy', 0.5, 44000);
    console.log('');

    // Test valid sell orders
    console.log('🧪 Testing valid sell orders...');
    await createTransaction(user1.id, 'USDT', 'sell', 1000, 1);
    await createTransaction(user2.id, 'ETH', 'sell', 2, 3100);
    console.log('');

    // Test insufficient balance
    console.log('🧪 Testing insufficient balance...');
    await createTransaction(user2.id, 'BTC', 'buy', 1, 100000); // Too expensive
    console.log('');

    // Test invalid symbol
    console.log('🧪 Testing invalid symbol...');
    await createTransaction(user1.id, 'INVALID', 'buy', 1, 100);
    console.log('');

    // Test invalid type
    console.log('🧪 Testing invalid type...');
    const options = {
        hostname: API_HOST,
        port: API_PORT,
        path: '/transactions',
        method: 'POST',
        headers: {
            'Content-Type': 'application/json',
        },
    };

    try {
        const response = await makeRequest(options, {
            userId: user1.id,
            symbol: 'BTC',
            type: 'invalid',
            quantity: 1,
            price: 100
        });
        console.log('Response:', response.statusCode, response.body.error);
    } catch (error) {
        console.error('Error:', error.message);
    }
    console.log('');

    // Test negative values
    console.log('🧪 Testing negative values...');
    await createTransaction(user1.id, 'BTC', 'buy', -1, 100);
    await createTransaction(user1.id, 'BTC', 'buy', 1, -100);
    console.log('');
}

// Run if called directly
if (require.main === module) {
    testCreateTransactions();
}

module.exports = { createTransaction, testCreateTransactions };