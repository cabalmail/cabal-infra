import React, { useState, useEffect, useCallback } from 'react';
import useApi from '../hooks/useApi';
import { ADDRESS_LIST } from '../constants';

function List({ setMessage, regenerate }) {
  const api = useApi();
  const [filter, setFilter] = useState("");
  const [addresses, setAddresses] = useState([]);

  const sortAddresses = (items) => {
    return items.slice().sort((a, b) => {
      if (a.address > b.address) return 1;
      if (a.address < b.address) return -1;
      return 0;
    });
  };

  const filterAndSort = useCallback((items, filterText) => {
    const filtered = items.filter(a =>
      [a.address, a.comment].join('.')
        .toLowerCase()
        .includes(filterText.toLowerCase())
    );
    return sortAddresses(filtered);
  }, []);

  const fetchAndSet = useCallback((filterText) => {
    api.getAddresses().then(data => {
      try {
        localStorage.setItem(ADDRESS_LIST, JSON.stringify(data));
      } catch (e) {
        console.log(e);
      }
      if (filterText) {
        setAddresses(filterAndSort(data.data.Items, filterText));
      } else {
        setAddresses(sortAddresses(data.data.Items));
      }
    });
  }, [api, filterAndSort]);

  // Initial load
  useEffect(() => {
    fetchAndSet("");
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // When regenerate changes, scroll to new address and reload
  useEffect(() => {
    if (!regenerate) return;
    const newAddress = document.getElementById(regenerate);
    if (newAddress) {
      newAddress.scrollIntoView({ behavior: "smooth", block: "nearest", inline: "nearest" });
    }
    localStorage.removeItem(ADDRESS_LIST);
    fetchAndSet(filter);
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [regenerate]);

  // When filter changes, refetch and filter
  useEffect(() => {
    fetchAndSet(filter);
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [filter]);

  const revoke = (e) => {
    e.preventDefault();
    const address = e.target.value;
    const found = addresses.find(a => a.address === address);
    api.deleteAddress(found.address, found.subdomain, found.tld, found.public_key).then(() => {
      setMessage("Successfully revoked address.", false);
      setAddresses(prev => prev.filter(a => a.address !== address));
    }, reason => {
      setMessage("Request to revoke address failed.", true);
      console.error("Promise rejected", reason);
    });
  };

  const copy = (e) => {
    e.preventDefault();
    const address = e.target.value;
    navigator.clipboard.writeText(address);
    setMessage(`The address ${address} has been copied to your clipboard.`, false);
  };

  const reload = (e) => {
    e.preventDefault();
    fetchAndSet(filter);
  };

  const addressList = addresses.map(a => {
    let className = "address";
    if (a.address === regenerate) {
      className = "address active";
    }
    return (
      <li key={a.address} className={className} id={a.address}>
        <span>{a.address.replace(/([.@])/g, "$&\u200B")}</span>
        <span>{a.comment}</span>
        <button onClick={copy} value={a.address} title="Copy this address">&#128203;</button>
        <button onClick={revoke} value={a.address} title="Revoke this address">&#128465;&#65039;</button>
      </li>
    );
  });

  return (
    <div className="list">
      <form className="list-form" onSubmit={(e) => e.preventDefault()}>
        <input
          type="text"
          value={filter}
          onChange={(e) => setFilter(e.target.value)}
          id="filter"
          name="filter"
          placeholder="filter"
        />
        <button id="reload" onClick={reload} title="Reload addresses">&#10227;</button>
      </form>
      <div id="count">Found: {addresses.length} addresses</div>
      <div id="list">
        <ul className="address-list">
          {addressList}
        </ul>
      </div>
    </div>
  );
}

export default List;
