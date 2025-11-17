-- Init schema for db_test trading system
-- Run on primary pg-1

-- Create database if not exists
-- Note: In PostgreSQL, CREATE DATABASE cannot be in a transaction, so run separately if needed
-- psql -U postgres -c "CREATE DATABASE db_test;"

-- Connect to db_test
-- psql -U postgres -d db_test -f init_trading_schema.sql

-- Create extensions if needed
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- Users table
CREATE TABLE users (
    id SERIAL PRIMARY KEY,
    username VARCHAR(50) UNIQUE NOT NULL,
    email VARCHAR(100) UNIQUE NOT NULL,
    balance NUMERIC(15,2) DEFAULT 0.00 CHECK (balance >= 0),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Symbols table (e.g., BTC, ETH)
CREATE TABLE symbols (
    id SERIAL PRIMARY KEY,
    symbol VARCHAR(10) UNIQUE NOT NULL,
    name VARCHAR(100) NOT NULL
);

-- Orders table
CREATE TABLE orders (
    id SERIAL PRIMARY KEY,
    user_id INTEGER REFERENCES users(id) ON DELETE CASCADE,
    symbol_id INTEGER REFERENCES symbols(id) ON DELETE CASCADE,
    type VARCHAR(4) CHECK (type IN ('buy', 'sell')) NOT NULL,
    quantity INTEGER NOT NULL CHECK (quantity > 0),
    price NUMERIC(15,8) NOT NULL CHECK (price > 0),
    status VARCHAR(10) DEFAULT 'pending' CHECK (status IN ('pending', 'filled', 'cancelled')),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Trades table (executed matches)
CREATE TABLE trades (
    id SERIAL PRIMARY KEY,
    buy_order_id INTEGER REFERENCES orders(id) ON DELETE CASCADE,
    sell_order_id INTEGER REFERENCES orders(id) ON DELETE CASCADE,
    quantity INTEGER NOT NULL CHECK (quantity > 0),
    price NUMERIC(15,8) NOT NULL CHECK (price > 0),
    executed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Indexes for performance
CREATE INDEX idx_orders_user_id ON orders(user_id);
CREATE INDEX idx_orders_symbol_id ON orders(symbol_id);
CREATE INDEX idx_orders_status ON orders(status);
CREATE INDEX idx_trades_buy_order_id ON trades(buy_order_id);
CREATE INDEX idx_trades_sell_order_id ON trades(sell_order_id);

-- Insert sample data
INSERT INTO symbols (symbol, name) VALUES
('BTC', 'Bitcoin'),
('ETH', 'Ethereum'),
('USDT', 'Tether');

INSERT INTO users (username, email, balance) VALUES
('trader1', 'trader1@example.com', 10000.00),
('trader2', 'trader2@example.com', 5000.00);

-- Sample orders
INSERT INTO orders (user_id, symbol_id, type, quantity, price) VALUES
(1, 1, 'buy', 1, 50000.00),
(2, 1, 'sell', 1, 51000.00);

-- Function to update updated_at
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ language 'plpgsql';

CREATE TRIGGER update_orders_updated_at BEFORE UPDATE ON orders
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();