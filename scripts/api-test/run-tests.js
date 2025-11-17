#!/usr/bin/env node

const path = require('path');

console.log('🚀 Running All Trading API Tests');
console.log('=' .repeat(60));

async function runTest(testName, testFunction) {
    console.log(`\n▶️  Starting ${testName}...`);
    console.log('-'.repeat(40));

    try {
        await testFunction();
        console.log(`✅ ${testName} completed successfully`);
    } catch (error) {
        console.error(`❌ ${testName} failed:`, error.message);
    }

    console.log('='.repeat(60));
}

async function runAllTests() {
    // Test Create User
    const userTest = require('./test-create-user');
    await runTest('Create User API Test', userTest.testCreateUsers);

    // Test Create Transaction
    const transactionTest = require('./test-create-transaction');
    await runTest('Create Transaction API Test', transactionTest.testCreateTransactions);

    // Test View Profile
    const profileTest = require('./test-view-profile');
    await runTest('View Profile API Test', profileTest.testViewProfile);

    console.log('\n🎉 All tests completed!');
    console.log('📊 Check the output above for detailed results');
    console.log('🔗 API Server should be running at http://localhost:3000');
    console.log('📖 API Endpoints:');
    console.log('   POST /users - Create user');
    console.log('   POST /transactions - Create order');
    console.log('   GET /profile/:userId - View user profile');
    console.log('   GET /health - Health check');
}

async function runSpecificTest(testName) {
    const tests = {
        'user': './test-create-user',
        'transaction': './test-create-transaction',
        'profile': './test-view-profile'
    };

    if (!tests[testName]) {
        console.log('❌ Invalid test name. Available tests: user, transaction, profile');
        return;
    }

    const testModule = require(tests[testName]);
    const testFunctionName = `test${testName.charAt(0).toUpperCase() + testName.slice(1)}${testName === 'user' ? 's' : testName === 'transaction' ? 's' : ''}`;

    if (typeof testModule[testFunctionName] === 'function') {
        await runTest(`${testName} Test`, testModule[testFunctionName]);
    } else {
        console.log(`❌ Test function ${testFunctionName} not found`);
    }
}

// Main execution
const args = process.argv.slice(2);
if (args.length > 0) {
    const testName = args[0].toLowerCase();
    runSpecificTest(testName);
} else {
    runAllTests();
}