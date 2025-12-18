USE app;

INSERT IGNORE INTO users (email, full_name)
VALUES
    ('alice@example.com', 'Alice Doe'),
    ('bob@example.com', 'Bob Doe');

INSERT IGNORE INTO orders (id, user_id, amount_cents, status)
VALUES
    (1, 1, 1999, 'created'),
    (2, 2, 4999, 'created');
